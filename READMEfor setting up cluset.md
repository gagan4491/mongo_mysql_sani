# Build the independent RND MongoDB replica set from a source backup

Runbook prepared 2026-10-22 for the environment used in this chat. Execute sections in order, on the named server. This is an operator runbook, not an unattended script. Stop if a command fails or its output differs from the stated expectation.

## Target and prerequisites

| Role | Hostname | IP | Final votes | Final priority |
|---|---|---|---:|---:|
| Preferred primary | rnd-aperture-mongo1 | 10.10.50.246 | 1 | 3 |
| Secondary / alternate primary | rnd-aperture-mongo2 | 10.10.50.248 | 1 | 2 |
| Restore seed / initial primary | rnd-aperture-mongo3 | 10.10.50.247 | 1 | 1 |

- Source: `mongo3.fleetdefense.com:27017`, member of `rs0`. Confirm it is healthy before backup.
- Target replica set: `rndrs`, independent of `rs0`.
- Matching Percona Server for MongoDB **4.2.25-25**, WiredTiger, x86_64 on all target nodes. Provision the OS, disks, packages, `mongo` shell, `rsync`, and service before starting. This runbook does not guess legacy package repository/install commands.
- Source feature compatibility version (FCV): **4.0**; keep it unchanged for this copy.
- Target data directory: `/var/lib/mongodb`, service/user/group: `mongod`.
- Source backup path: `/backup/hotbackups/env2-copy`; staging path on RND mongo3: `/backup/env2-copy`.
- Observed backup: approximately 278 GiB physical files. This size is an observation, not a fixed requirement for future backups.
- Each target stores the FULL dataset. Budget data, indexes, oplog, logs and growth on each node. The observed 393 GiB volumes had about 96 GiB free after restoration; monitor this headroom.
- Original environment stays running. RND remains unavailable to applications during restore/seeding.
- MongoDB 4.2 is end of life. This reproduces the required legacy setup; schedule its upgrade separately.

### Safety rules

1. Never delete or reset replication metadata on the original source.
2. Check `hostname -f` before destructive commands. Deletion sections below apply ONLY to the specified RND node and discard its existing data.
3. Keep the completed original backup intact until validation and a new destination backup are complete.
4. Never rsync a running MongoDB data directory. Use a successful hot backup, a supported consistent snapshot, or cleanly stop MongoDB for the entire copy.
5. Drop `local` ONLY when converting the original source backup into the independent RND seed. Retain `local` when copying that initialized RND seed to other RND members.
6. Never run `rs.initiate()` on mongo1/mongo2. Never use `rs.reconfig(...,{force:true})` in this workflow.
7. Commands assume authentication is disabled, as verified in this environment. Linux root and MongoDB users are separate. If authentication is enabled, use authorized database credentials and internal replica-set authentication.
8. With authentication disabled, restrict TCP 27017 to intended RND nodes and authorized clients before binding to a network IP. Explicit bind addresses alone are not access control.
9. Keep applications, consumers, scheduled jobs, payments, email and outbound integrations disconnected until environment settings and copied sensitive data are reviewed.

## 1. Inspect the source (read-only)

On the source database server:

```bash
hostname -f
mongod --version
mongo --quiet --eval 'printjson(rs.status())'
mongo admin --quiet --eval 'printjson(db.adminCommand({getParameter:1,featureCompatibilityVersion:1})); rs.printReplicationInfo()'
mongo --quiet --eval 'var c=rs.conf(); print(c._id); c.members.forEach(function(m){printjson({host:m.host,votes:m.votes,priority:m.priority})})'
```

Observed source priorities: mongo1=3, mongo2=2, mongo3=1, all votes=1. Verify actual values each time. A current source count can differ from the eventual backup point if writes continue.

## 2. Create a physical hot backup on the source secondary

Run filesystem preparation ON `mongo3.fleetdefense.com`, not on an unrelated shell host. The server executes `createBackup` and writes to its own filesystem.

```bash
mkdir -p /backup/hotbackups
chown mongod:mongod /backup/hotbackups
chmod 750 /backup/hotbackups
df -h /backup/hotbackups
ps -eo user,pid,args | grep '[m]ongod'
test ! -e /backup/hotbackups/env2-copy && echo 'Fresh backup path available'
```

If the final backup directory already exists, select a NEW path and update subsequent commands; do not overwrite it. Ensure free space covers the physical dataset plus growth/margin. Stop any obsolete mongodump job before starting another heavy backup.

Run in a persistent terminal session. `tee` records command output, not a live percentage:

```bash
set -o pipefail
mongo --host='mongo3.fleetdefense.com:27017' admin <<'JS' 2>&1 | tee /backup/createBackup-env2.log
var r=db.runCommand({createBackup:1,backupDir:'/backup/hotbackups/env2-copy'});
printjson(r);
if(r.ok!==1) quit(1);
JS
```

Require `"ok": 1`. A shell connection alone does not establish backup success. On the source, monitor:

```bash
du -sh /backup/hotbackups/env2-copy
df -h /backup
tail -f /var/log/mongodb/mongod.log
```

Do not assume the source remains unaffected: monitor disk load and replication lag. This backup captures a point in time; it is not ongoing synchronization.

## 3. Transfer backup to RND mongo3

Run ON the source backup server, after successful backup:

```bash
rsync -a --info=progress2 /backup/hotbackups/env2-copy/ root@10.10.50.247:/backup/env2-copy/
echo $?
```

Require exit code `0`. Verify checksums with a non-modifying comparison:

```bash
rsync -anc --itemize-changes /backup/hotbackups/env2-copy/ root@10.10.50.247:/backup/env2-copy/
```

Expect no content differences. Checksum verification reads all backup data on both sides and takes time. On RND mongo3:

```bash
du -sh /backup/env2-copy
ls -l /backup/env2-copy/WiredTiger /backup/env2-copy/WiredTiger.backup
```

## 4. Configure target names and network

On ALL THREE RND nodes, preserve unrelated `/etc/hosts` entries and add:

```text
10.10.50.246 rnd-aperture-mongo1
10.10.50.247 rnd-aperture-mongo3
10.10.50.248 rnd-aperture-mongo2
```

Remove these hostnames from conflicting loopback entries such as `127.0.1.1`. Keep `127.0.0.1 localhost` and unrelated IPv6 entries. Alternatively configure equivalent stable DNS.

```bash
getent ahostsv4 rnd-aperture-mongo1
getent ahostsv4 rnd-aperture-mongo2
getent ahostsv4 rnd-aperture-mongo3
```

Each name must resolve to its RND IP on every member and client host.

Back up `/etc/mongod.conf` on each target before editing:

```bash
cp -a /etc/mongod.conf /etc/mongod.conf.before-rnd
```

Merge these into existing sections; do not duplicate YAML keys:

```yaml
storage:
  dbPath: /var/lib/mongodb
  journal:
    enabled: true
  wiredTiger:
    engineConfig:
      cacheSizeGB: 16

net:
  port: 27017
  bindIp: "127.0.0.1,10.10.50.247"

replication:
  replSetName: "rndrs"

setParameter:
  ttlMonitorEnabled: false
```

Use `.247` on mongo3, `.248` on mongo2, `.246` on mongo1. The 16 GiB cache matches this deployment; verify each server has sufficient RAM. Retain the working packaged systemLog/processManagement settings. Keep services stopped until instructed below.

TTL stays disabled during validation so expired copied records are not deleted unexpectedly.

## 5. Restore original backup onto RND mongo3

ONLY on `rnd-aperture-mongo3`:

```bash
hostname -f
systemctl stop mongod
pgrep -a mongod
df -h /var/lib/mongodb /backup
du -sh /backup/env2-copy
ls -l /backup/env2-copy/WiredTiger /backup/env2-copy/WiredTiger.backup
```

Require correct hostname, no running mongod, and verified backup. The next command permanently discards existing target data. Preserve it elsewhere first if needed. Do not remove the mounted directory itself:

```bash
find /var/lib/mongodb -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
rsync -a --info=progress2 /backup/env2-copy/ /var/lib/mongodb/
echo $?
```

Require `0`, then:

```bash
chown -R mongod:mongod /var/lib/mongodb
du -sh /var/lib/mongodb
df -h /var/lib/mongodb
```

## 6. Convert source identity into an independent RND seed

On RND mongo3, keep the normal service stopped. Start a temporary standalone bound ONLY to localhost port 27018, without the normal configuration file:

```bash
runuser -u mongod -- /usr/bin/mongod --dbpath /var/lib/mongodb --bind_ip 127.0.0.1 --port 27018 --wiredTigerCacheSizeGB 16 --setParameter ttlMonitorEnabled=false --logpath /var/lib/mongodb/restore-standalone.log --fork
```

Inspect the effective options and databases BEFORE dropping metadata:

```bash
mongo --host 127.0.0.1 --port 27018 admin --quiet --eval 'printjson(db.adminCommand({getCmdLineOpts:1})); printjson(db.adminCommand({listDatabases:1,nameOnly:true}))'
```

Confirm `/var/lib/mongodb`, port 27018, no replication option, and `learninglocker_v2` present. The warning about copied `local.system.replset` during standalone maintenance is expected.

ONLY on this RND standalone, drop the copied source replication metadata:

```bash
mongo --host 127.0.0.1 --port 27018 local --quiet --eval 'printjson(db.dropDatabase())'
mongo --host 127.0.0.1 --port 27018 admin --quiet --eval 'printjson(db.adminCommand({getParameter:1,featureCompatibilityVersion:1}))'
```

Require `dropped: local`, `ok: 1`, FCV `4.0`. Do NOT drop the application database. Do not raise FCV as part of this copy.

Shut down cleanly:

```bash
mongo --host 127.0.0.1 --port 27018 admin --eval 'db.shutdownServer()'
pgrep -a mongod
```

A connection-closed message at shutdown is normal. Require no mongod process before proceeding.

## 7. Initialize rndrs on mongo3

Check section 4 configuration, then on RND mongo3:

```bash
systemctl start mongod
systemctl status mongod --no-pager
mongo admin --quiet --eval 'printjson(rs.initiate({_id:"rndrs",members:[{_id:0,host:"rnd-aperture-mongo3:27017"}]}))'
```

Run `rs.initiate()` ONCE. Require `ok: 1`. Wait for election, then:

```bash
mongo --quiet --eval 'printjson(db.isMaster())'
mongo admin --quiet --eval 'printjson(db.adminCommand({listDatabases:1,nameOnly:true})); printjson(db.adminCommand({getParameter:1,featureCompatibilityVersion:1}))'
```

Require `ismaster: true`, setName `rndrs`, application database present, FCV `4.0`. The new `local` database is expected.

## 8. Seed mongo2 and mongo1 from the initialized RND node

This chosen method copies physical files and existing indexes to avoid a full logical initial sync. It requires RND downtime. The original source/QA environment stays running.

IMPORTANT: use the initialized RND mongo3 files, NOT the original `rs0` backup. Retain the RND `local` database and oplog in the copy.

1. Keep applications paused.
2. On mongo1 and mongo2, verify hostname and stop MongoDB:

```bash
hostname -f
systemctl stop mongod
pgrep -a mongod
```

3. On mongo3, stop MongoDB cleanly:

```bash
systemctl stop mongod
pgrep -a mongod
```

Require no mongod processes on all copy participants. Keep mongo3 stopped until BOTH copies and verification finish.

4. On EACH destination mongo1/mongo2, discard only its existing/partial data after confirming no data must be preserved:

```bash
find /var/lib/mongodb -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
```

5. On mongo3, transfer sequentially:

```bash
rsync -a --info=progress2 /var/lib/mongodb/ root@10.10.50.248:/var/lib/mongodb/
echo $?
```

Require `0` before proceeding:

```bash
rsync -a --info=progress2 /var/lib/mongodb/ root@10.10.50.246:/var/lib/mongodb/
echo $?
```

Require `0`. For checksum verification while servers remain stopped:

```bash
rsync -anc --itemize-changes /var/lib/mongodb/ root@10.10.50.248:/var/lib/mongodb/
rsync -anc --itemize-changes /var/lib/mongodb/ root@10.10.50.246:/var/lib/mongodb/
```

Require no content differences. On mongo1 and mongo2:

```bash
chown -R mongod:mongod /var/lib/mongodb
```

6. Start mongo3 FIRST and wait for primary:

```bash
systemctl start mongod
mongo --quiet --eval 'printjson(db.isMaster())'
```

7. Start mongo2 and mongo1 using their section 4 configurations:

```bash
systemctl start mongod
```

They may temporarily report REMOVED because the copied configuration does not list them yet. Do not initialize them separately or drop their `local` database.

8. On PRIMARY mongo3, add mongo2 as nonvoting:

```bash
mongo admin --quiet --eval 'if(rs.conf()._id!=="rndrs") throw "Wrong replica set"; printjson(rs.add({host:"rnd-aperture-mongo2:27017",priority:0,votes:0}))'
```

Wait until mongo2 is healthy SECONDARY before adding mongo1:

```bash
mongo --quiet --eval 'rs.status().members.forEach(function(m){print(m.name+" "+m.stateStr+" health="+m.health)})'
```

Then:

```bash
mongo admin --quiet --eval 'if(rs.conf()._id!=="rndrs") throw "Wrong replica set"; printjson(rs.add({host:"rnd-aperture-mongo1:27017",priority:0,votes:0}))'
```

If a node was ALREADY added before the physical copy, skip its `rs.add()`; inspect `rs.conf()` first. Successful seeding should recover and catch up rather than rebuild the full dataset. If STARTUP2 persists, inspect logs before restarting/deleting anything. Enough source oplog history must remain for catch-up; never assume the original QA oplog window applies to this new set.

## 9. Verify health and catch-up

On mongo3:

```bash
mongo --quiet --eval 'rs.status().members.forEach(function(m){printjson({host:m.name,state:m.stateStr,health:m.health,message:m.lastHeartbeatMessage})})'
mongo --quiet --eval 'rs.printSecondaryReplicationInfo()'
mongo --quiet --eval 'rs.printReplicationInfo()'
```

Require mongo3 PRIMARY, mongo2/mongo1 SECONDARY, all health=1, with minimal stable replication lag. A few seconds can reflect reporting/no-op timing; inspect trends and optimes before assuming a stall.

## 10. Enable voting, then set preferred primary

Run ON THE CURRENT RND PRIMARY. Require all members healthy and caught up. Change only one voting member per reconfiguration. Do not proceed if any change fails.

Enable mongo2 vote, keeping priority=0:

```bash
mongo admin --quiet --eval 'var c=rs.conf(); if(c._id!=="rndrs") throw "Wrong replica set"; c.members.forEach(function(m){if(m.host==="rnd-aperture-mongo2:27017") m.votes=1;}); printjson(rs.reconfig(c))'
```

Wait and verify health/configuration on all three members before the next change:

```bash
mongo --quiet --eval 'rs.status().members.forEach(function(m){print(m.name+" "+m.stateStr+" health="+m.health)}); print("Config version: "+rs.conf().version)'
```

Run that check locally on each member to confirm the configuration version agrees. Then enable mongo1 vote:

```bash
mongo admin --quiet --eval 'var c=rs.conf(); if(c._id!=="rndrs") throw "Wrong replica set"; c.members.forEach(function(m){if(m.host==="rnd-aperture-mongo1:27017") m.votes=1;}); printjson(rs.reconfig(c))'
```

Again verify healthy states and matching configuration versions on all members. Check lag:

```bash
mongo --quiet --eval 'rs.printSecondaryReplicationInfo()'
```

Apply final priorities on the current primary:

```bash
mongo admin --quiet --eval 'var c=rs.conf(); if(c._id!=="rndrs") throw "Wrong replica set"; var p={"rnd-aperture-mongo1:27017":3,"rnd-aperture-mongo2:27017":2,"rnd-aperture-mongo3:27017":1}; c.members.forEach(function(m){if(p[m.host]===undefined) throw "Unexpected member"; m.priority=p[m.host];}); printjson(rs.reconfig(c))'
```

This can trigger an election and briefly interrupt writes. Wait for mongo1 to become PRIMARY; priority is a preference, not a permanent pin. Do not force an election while diagnosing a lagging node.

```bash
mongo --quiet --eval 'rs.status().members.forEach(function(m){print(m.name+" "+m.stateStr+" health="+m.health)}); var c=rs.conf(); print("Replica set: "+c._id); c.members.forEach(function(m){printjson({host:m.host,votes:m.votes,priority:m.priority})})'
```

Expected: mongo1 PRIMARY, mongo2/mongo3 SECONDARY, health=1, all votes=1, priorities 3/2/1. Three voters require two votes for a majority. A nonvoter/priority-zero member cannot become primary.

## 11. Data and application validation

On the current RND primary, fast collection and statement metadata checks:

```bash
mongo learninglocker_v2 --quiet --eval 'print("Collections: "+db.getCollectionInfos({type:"collection"}).length); print("Statements estimate: "+db.statements.estimatedDocumentCount()); printjson(db.statements.getIndexes())'
```

Exact count (can scan the large collection and take a long time):

```bash
mongo learninglocker_v2 --quiet --eval 'print(db.statements.countDocuments({}))'
```

Do not run expensive counts while diagnosing replication performance. Counts alone do not prove content equality. Validate collection/index definitions, sampled important records and business totals against the same backup point.

During this setup, the supplied expected statement count was **192,322,481**, but initial-sync metadata reported **185,330,129**. That difference of **6,992,352** remains to be reconciled; do not silently declare an exact source match. Check backup timing, TTL/deletions, expected-count provenance and restore logs. Metadata counts are estimates, and current source writes can change the comparison.

Before application access:

- Review restored users/roles; use separate RND credentials.
- Mask sensitive data if required.
- Replace production integrations, email/payment/webhook endpoints and schedules.
- Review TTL indexes. To list them:

```bash
mongo learninglocker_v2 --quiet --eval 'db.getCollectionInfos({type:"collection"}).forEach(function(c){db.getCollection(c.name).getIndexes().forEach(function(i){if(i.expireAfterSeconds!==undefined) printjson({collection:c.name,index:i})})})'
```

If expiry is intended, remove `ttlMonitorEnabled: false` (or change it to true) in the config on ALL nodes, then apply through a planned rolling restart with health checks. Do not leave inconsistent TTL settings that change behavior at failover. Re-enabling can delete expired copied records immediately.

- Configure backups/monitoring and verify a destination restore before retiring the original backup.
- Enable service startup on all RND nodes:

```bash
systemctl enable mongod
```

Example application connection string (all hostnames must resolve from the application):

```text
mongodb://rnd-aperture-mongo1:27017,rnd-aperture-mongo2:27017,rnd-aperture-mongo3:27017/learninglocker_v2?replicaSet=rndrs
```

Add the approved authentication/TLS settings for your deployment. Use a replica-set URI so the driver follows elections.

## Troubleshooting

### Member unreachable / health=0

On the affected member:

```bash
systemctl status mongod --no-pager
ss -lntp | grep 27017
tail -n 60 /var/log/mongodb/mongod.log
```

From another RND member:

```bash
getent ahostsv4 rnd-aperture-mongo1
mongo --host rnd-aperture-mongo1 --quiet --eval 'printjson(db.adminCommand({ping:1}))'
```

Substitute the affected hostname. Verify hostname mappings, bind IP, TCP firewall rules, same `rndrs` name and matching authentication settings in both directions. Do not rerun rs.add for an existing member.

### NotYetInitialized

For the first independent seed, initialize ONCE as in section 7. For additional nodes, add them from the existing primary; do not initialize a separate set.

### STARTUP2 / initial-sync progress

If using logical sync instead of physical seeding, query the syncing member:

```bash
mongo admin --quiet --eval 'var s=db.adminCommand({replSetGetStatus:1,initialSync:1}); var p=s.initialSyncStatus; if(p) printjson({copiedGB:p.approxTotalBytesCopied/1e9,totalGB:p.approxTotalDataSize/1e9,elapsedMinutes:p.totalInitialSyncElapsedMillis/60000,remainingHours:p.remainingInitialSyncEstimatedMillis/3600000,failedAttempts:p.failedInitialSyncAttempts}); else printjson({state:s.myState,ok:s.ok})'
```

ETAs vary; compare copied-byte changes across 5–10 minutes and inspect logs. Index work may dominate. Logical byte totals can exceed compressed disk usage. Do not copy live data files as a shortcut.

### AuthenticationFailed

Linux root does not confer MongoDB privileges. Use real MongoDB credentials/auth database if enabled. In this specific deployment no credentials were required; providing a nonexistent admin login caused authentication failure.

### Recovery / rollback

If restoration fails, stop the destination and inspect logs. Preserve the original `/backup/env2-copy`. Never use `--repair`, delete WiredTiger files selectively, or force reconfiguration without diagnosing the failure. Source rs0 remains independent and is not modified by this workflow. Once RND accepts writes, replacing it with the old backup discards those newer RND writes.

## References

- [Percona Server for MongoDB 4.2.25-25 manual: hot backup and physical restore](https://docs.percona.com/legacy-documentation/percona-server-for-mongodb/Percona-Server-for-MongoDB-4.2.25-25.pdf)
- [MongoDB: restore a replica set from a backup](https://www.mongodb.com/docs/manual/tutorial/restore-replica-set-from-backup/)
- [MongoDB: seed/resync a member, including its local database](https://www.mongodb.com/docs/v8.3/tutorial/resync-replica-set-member/)
- [MongoDB: replica-set reconfiguration and one-voter changes](https://www.mongodb.com/docs/v7.0/reference/method/rs.reconfig/)

The Percona 4.2 manual is the version-specific source. Newer MongoDB references explain general replication mechanics; do not assume newer commands/features exist in 4.2.
