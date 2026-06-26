import 'package:flutter/foundation.dart';
import '../db/dao/memory_dao.dart';
import '../db/database.dart';
import '../models/memory.dart';

/// 记忆的唯一写入口——所有增/改/软删都从这里走。
///
/// 同 [CalendarRepository] 的纪律：
/// - **盖戳**：每次写统一刷新 `updatedAt`（UTC, 单调护栏），让 P2 加密备份的
///   LWW 合并能识别"较新者胜"。
/// - **写后读 / 读改写**：update / clearAll 走事务，避免 UI 操作和后台归纳器
///   并发交错时丢失中间态。
/// - **副作用钩子**：当前是 `_afterWriteHook()` 空实现；P2 起接到 BackupService。
class MemoryRepository {
  final PikppoDatabase _db;
  final MemoryDao _dao;

  /// 单调钟守卫——按域独立维护，防止设备时钟回拨导致同一行 updatedAt 倒退。
  DateTime _lastStamp = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  MemoryRepository(this._db) : _dao = MemoryDao(_db);

  // ---------- 写 ----------

  /// 新增记忆。memory.id 由调用方生成（沿用现有 UUID 流）。
  Future<Memory> add(Memory memory) async {
    final stamped = _monotonicStamp();
    await _dao.upsert(memory, stamped);
    _afterWriteHook();
    return memory;
  }

  /// 软删——保留墓碑，盖戳推进 updatedAt，让备份/恢复链能识别删除事实。
  Future<void> delete(String id) async {
    final stamped = _monotonicStamp();
    await _dao.markDeleted(id, updatedAtUtc: stamped);
    _afterWriteHook();
  }

  /// 全清：墓碑化所有存活记忆。事务内一次完成，避免半途崩盘留下不一致。
  Future<int> clearAll() async {
    final stamped = _monotonicStamp();
    final count = await _db.transaction(
        () => _dao.markAllDeleted(updatedAtUtc: stamped));
    _afterWriteHook();
    return count;
  }

  /// 后台归纳器一轮提交——updated 与 added 共用同一时间戳，事务内一次落盘。
  Future<void> applyDiff({
    required Iterable<Memory> updated,
    required Iterable<Memory> added,
  }) async {
    final all = [...updated, ...added];
    if (all.isEmpty) return;
    final stamped = _monotonicStamp();
    await _db.transaction(() => _dao.upsertBatch(all, stamped));
    _afterWriteHook();
  }

  // ---------- 读（DAO 已滤墓碑） ----------

  Future<List<Memory>> all() => _dao.allAlive();
  Future<Memory?> getById(String id) => _dao.getById(id);

  // ---------- 私有 ----------

  /// 客户端单调钟：now < `_lastStamp` 时强制 `_lastStamp + 1ms`——LWW 合并的
  /// 正确性依赖时间单调，设备时钟回拨（NTP 校正 / 用户改表）不应让自己的连续
  /// 编辑被自己的旧版本击败。
  DateTime _monotonicStamp() {
    final now = DateTime.now().toUtc();
    if (now.isAfter(_lastStamp)) {
      _lastStamp = now;
    } else {
      _lastStamp = _lastStamp.add(const Duration(milliseconds: 1));
    }
    return _lastStamp;
  }

  void _afterWriteHook() {
    // Phase 1：空实现。
    // Phase 2：触发 BackupService.requestBackup()（防抖 5 分钟）。
    assert(() {
      debugPrint('memory sync hook (no-op in Phase 1)');
      return true;
    }());
  }
}
