-- migrations/20260507120000_finalize_orphan_active_sessions.sql
-- 旧 gap-based session 管理 (web session control 導入前) の遺物として
-- ended_at IS NOT NULL かつ status='active' のまま残った row を finalized に揃える。
-- 進行中 session (ended_at IS NULL) には触らない。

UPDATE sessions
   SET status = 'finalized'
 WHERE status = 'active'
   AND ended_at IS NOT NULL;
