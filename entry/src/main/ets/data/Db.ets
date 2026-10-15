import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DB_NAME, SCHEMA_SQL } from './Schema';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/** 全局唯一的 RdbStore 持有者 */
export class Db {
  private static store: relationalStore.RdbStore | undefined = undefined;
  /** 正在打开中的 Promise：避免多个组件同时初始化时重复开库、重复建表 */
  private static opening: Promise<relationalStore.RdbStore> | undefined = undefined;
  /**
   * 当前连的是哪个库。默认真实库；「新手演练」期间会切成沙箱库（见 `Schema.DEMO_DB_NAME`）。
   * ⚠️ 进程重启后回到默认值 —— 沙箱绝不会"粘"到下一次冷启动上。
   */
  private static activeName: string = DB_NAME;

  /** 当前库名（诊断/日志用） */
  static currentName(): string {
    return Db.activeName;
  }

  /** 取连接（首次调用会建表） */
  static async get(context: common.Context): Promise<relationalStore.RdbStore> {
    if (Db.store !== undefined) {
      return Db.store;
    }
    if (Db.opening === undefined) {
      Db.opening = Db.open(context);
    }
    return await Db.opening;
  }

  /**
   * 换一个库连（「新手演练」进出沙箱用）。
   * 关掉旧连接、清掉缓存的 Promise，再按新库名开一次（建表 + 迁移都会重跑）。
   */
  static async use(context: common.Context, name: string): Promise<void> {
    if (Db.activeName === name && Db.store !== undefined) {
      return;
    }
    Db.store = undefined;
    Db.opening = undefined;
    Db.activeName = name;
    hilog.info(DOMAIN, TAG, 'switch database to %{public}s', name);
    await Db.get(context);
  }

  private static async open(context: common.Context): Promise<relationalStore.RdbStore> {
    const config: relationalStore.StoreConfig = {
      name: Db.activeName,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    for (const sql of SCHEMA_SQL) {
      await store.executeSql(sql);
    }
    // CREATE TABLE IF NOT EXISTS 不会给已有表补列，所以老库要单独补
    await Db.ensureColumn(store, 'plan_block', 'lesson_id', 'lesson_id INTEGER NOT NULL DEFAULT 0');
    // 考试的结束时刻（v1.1）：老库里没有这一列
    await Db.ensureColumn(store, 'todo', 'end_at', "end_at TEXT NOT NULL DEFAULT ''");
    Db.store = store;
    hilog.info(DOMAIN, TAG, '%{public}s', 'database ready');
    return store;
  }

  /** 缺列就补上（迁移用，失败不致命） */
  private static async ensureColumn(store: relationalStore.RdbStore, table: string, column: string,
    ddl: string): Promise<void> {
    try {
      const rs = await store.querySql(`PRAGMA table_info(${table})`);
      let exists: boolean = false;
      while (rs.goToNextRow()) {
        if (rs.getString(rs.getColumnIndex('name')) === column) {
          exists = true;
        }
      }
      rs.close();
      if (!exists) {
        await store.executeSql(`ALTER TABLE ${table} ADD COLUMN ${ddl}`);
        hilog.info(DOMAIN, TAG, 'migrated: %{public}s.%{public}s', table, column);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'ensureColumn %{public}s.%{public}s failed: %{public}s',
        table, column, JSON.stringify(e));
    }
  }

  /** 彻底重置（重建引导用） */
  static async wipe(context: common.Context): Promise<void> {
    const name: string = Db.activeName;
    Db.store = undefined;
    Db.opening = undefined;
    await relationalStore.deleteRdbStore(context, name);
    hilog.info(DOMAIN, TAG, '%{public}s', 'database wiped');
  }

  /** 简单的 kv，用来记「上次同步到哪」这类状态 */
  static async getKv(context: common.Context, key: string): Promise<string> {
    const store = await Db.get(context);
    const rs = await store.querySql('SELECT v FROM kv WHERE k = ?', [key]);
    let value = '';
    if (rs.goToFirstRow()) {
      value = rs.getString(rs.getColumnIndex('v'));
    }
    rs.close();
    return value;
  }

  static async setKv(context: common.Context, key: string, value: string): Promise<void> {
    const store = await Db.get(context);
    await store.executeSql('INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)', [key, value]);
  }
}
