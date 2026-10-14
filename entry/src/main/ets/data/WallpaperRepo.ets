/**
 * 自定义背景（壁纸）。
 *
 * 用户要求：「为了让玻璃态更好看，应该允许自定义背景，当然没有自定义背景时才用渐变背景」。
 *
 * 三条设计决定：
 *  1. **选完立刻把图拷进 App 沙盒**（`filesDir`），只记沙盒路径。
 *     系统相册给的 URI 只在本次授权内可用，重启后就读不到了；
 *     拷进沙盒之后既不需要**申请相册权限**，也不依赖那次授权，更不联网。
 *  2. 每次换背景写**新文件名**（`wallpaper_<时间戳>.jpg`）并删掉旧文件：
 *     路径一变，UI 上那个 `@StorageLink` 就会重新解码，不会因为"同名覆盖"而显示旧图。
 *  3. 解码到**屏幕尺寸**再交给 `Image`：一张 12MP 的照片直接整份解码进内存太浪费，
 *     按屏幕大小降采样一次，既省内存也快。解码失败（文件被删/损坏）就返回 undefined，
 *     调用方自动退回渐变 —— 背景坏了不该让 App 崩或者白屏。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from './Db';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/** kv 里存"当前背景在沙盒里的路径" */
const KV_KEY: string = 'wallpaper_path';
/** 沙盒里的文件名前缀 */
const FILE_PREFIX: string = 'wallpaper_';
/**
 * kv 里存"背景的显示位置与缩放"（格式 `'fx,fy,zoom'`，解析/夹紧见 domain/Wallpaper）。
 * 存**归一化**的焦点而不是像素偏移：换屏幕、转横竖屏都不会让调好的构图跑偏。
 */
const KV_FOCUS: string = 'wallpaper_focus';

export class WallpaperRepo {

  /** 读回上次选的背景路径；'' = 没设置（用渐变兜底） */
  static async load(context: common.Context): Promise<string> {
    try {
      const p: string = await Db.getKv(context, KV_KEY);
      if (p.length === 0) {
        return '';
      }
      // 文件被外部清掉的情况也要兜住，否则会一直拿一个读不到的路径去解码
      return fs.accessSync(p) ? p : '';
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'wallpaper load failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  /**
   * 弹系统相册选一张，拷进沙盒并记下路径。
   * 返回新的沙盒路径；'' = 用户取消或失败（调用方保持原样）。
   */
  static async pick(context: common.Context): Promise<string> {
    const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    const opt: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    opt.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    opt.maxSelectNumber = 1;
    const res: photoAccessHelper.PhotoSelectResult = await picker.select(opt);
    if (res.photoUris.length === 0) {
      return '';   // 用户取消了
    }
    const uri: string = res.photoUris[0];
    const oldPath: string = await WallpaperRepo.load(context);
    const dest: string = `${context.filesDir}/${FILE_PREFIX}${Date.now()}.jpg`;
    const srcFile: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const dstFile: fs.File = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    try {
      fs.copyFileSync(srcFile.fd, dstFile.fd);
    } finally {
      fs.closeSync(srcFile);
      fs.closeSync(dstFile);
    }
    await Db.setKv(context, KV_KEY, dest);
    // 换新图之后把旧文件删掉，避免沙盒里越攒越多
    if (oldPath.length > 0 && oldPath !== dest) {
      WallpaperRepo.removeFile(oldPath);
    }
    hilog.info(DOMAIN, TAG, 'wallpaper set: %{public}s', dest);
    return dest;
  }

  /** 恢复默认渐变：删掉沙盒文件与记录 */
  /** 读回背景的位置/缩放（空串 = 没调过，等于居中不缩放） */
  static async loadFocus(context: common.Context): Promise<string> {
    try {
      return await Db.getKv(context, KV_FOCUS);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'wallpaper focus load failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  /** 存背景的位置/缩放 */
  static async saveFocus(context: common.Context, text: string): Promise<void> {
    await Db.setKv(context, KV_FOCUS, text);
  }

  static async clear(context: common.Context): Promise<void> {
    const oldPath: string = await WallpaperRepo.load(context);
    await Db.setKv(context, KV_KEY, '');
    // 位置也一起清掉：否则下次再选一张图，会莫名其妙沿用上一张的构图
    await Db.setKv(context, KV_FOCUS, '');
    if (oldPath.length > 0) {
      WallpaperRepo.removeFile(oldPath);
    }
  }

  private static removeFile(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'wallpaper remove failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 把背景图解码成**能盖满 maxW×maxH** 的 PixelMap（保持宽高比，不放大）。
   * 失败返回 undefined —— 调用方据此退回渐变。
   */
  static async decode(path: string, maxW: number, maxH: number): Promise<image.PixelMap | undefined> {
    if (path.length === 0) {
      return undefined;
    }
    let source: image.ImageSource | undefined = undefined;
    try {
      source = image.createImageSource(path);
      if (source === undefined) {
        return undefined;
      }
      const info: image.ImageInfo = await source.getImageInfo();
      const sw: number = info.size.width;
      const sh: number = info.size.height;
      if (sw <= 0 || sh <= 0 || maxW <= 0 || maxH <= 0) {
        return undefined;
      }
      // 盖满屏幕所需的倍率；>1（要放大）时夹到 1，别把糊图放得更大
      let scale: number = Math.max(maxW / sw, maxH / sh);
      if (scale > 1) {
        scale = 1;
      }
      const want: image.Size = {
        width: Math.max(1, Math.round(sw * scale)),
        height: Math.max(1, Math.round(sh * scale))
      };
      const opts: image.DecodingOptions = { desiredSize: want };
      const pm: image.PixelMap = await source.createPixelMap(opts);
      return pm;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'wallpaper decode failed: %{public}s', JSON.stringify(e));
      return undefined;
    } finally {
      if (source !== undefined) {
        try {
          source.release();
        } catch (e) {
          // 释放失败无所谓
        }
      }
    }
  }
}
