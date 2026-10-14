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

  private static async open(context: common.Context): Promise<relationalStore.RdbStore> {
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
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
    Db.store = undefined;
    Db.opening = undefined;
    await relationalStore.deleteRdbStore(context, DB_NAME);
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
