# Consistent hashing in our cache, compared with Redis Cluster

Research for Lab 5, grade 7. The cache is three Valkey shards (`redis-0..2`) that know nothing of
each other; the clients shard. The same algorithm is implemented twice, in the gateway
([`app/cache.py`](https://github.com/TimurCravtov/KahootWithUndeadGateway), Python) and in Resource and
Zombie (`src/infrastructure/cache/hash-ring.ts`, TypeScript). A test checks that both place a key alike.

## The problem with `hash(key) % N`

It splits keys evenly, but `N` is in the formula. From 3 to 4 shards a key stays only if
`h % 3 == h % 4`, which holds for 3 residues of 12: **75 % of the keys move**, in general `N/(N+1)`
when adding one. For a cache every moved key is a miss, all at the same time, all landing on the databases.
Losing one shard is as bad.

## Consistent hashing

1. The hash space is a ring of 2^64 positions. Ours: the first 8 bytes of `md5(text)`, big-endian.
2. Every shard is put on the ring at many points, `md5("redis-0:6379#0")`, `#1`, … `#159`.
3. A key belongs to the first point clockwise from its own hash (binary search in the sorted points,
   480 of them for 3 shards).

```
                0 / 2^64
             ·····┬·····
         A7 ·           · B3
       C1 ·               ·◄── key "resource:player:1"
         ·                 · A2   ── first point clockwise: shard A
       B9 ·               · C4
           ·             ·
             ···········
```

- **Adding** a shard only takes the arcs just before its new points: about `1/(N+1)` of the keys, and
  only from a neighbour to the new shard. No key moves between old shards.
- **Removing** a shard (or losing it) gives each of its arcs to the next point clockwise: only its own
  `1/N` of the keys move.
- **Virtual nodes** (`CACHE_VNODES`, 160) do two things. With one point per shard the arcs would be
  very unequal; with many, the share of each gets close to `1/N` (the deviation falls about as
  `1/sqrt(vnodes)`). And a lost shard's arcs lie between points of *all* others, so its load is
  shared out instead of doubling one neighbour. More points on one shard would give it more weight.

Measured (20 000 keys `player:0..19999`, 3 shards, 160 points):

| | `hash % N` | our ring |
|---|---|---|
| Keys moved, 3 → 4 shards | 75.2 % | 25.6 %, all to the new shard |
| Keys moved, a shard lost | 66.4 % | 34.5 %, only the lost one's |
| Share per shard | 33 % | 34.5 / 32.0 / 33.5 % |

## Failure and consistency in our cache

- A shard that errors or exceeds 250 ms is skipped for 5 s by the client that noticed; its keys go to
  the next shard clockwise, the others stay. It is a cache, so a moved key is only a miss.
- Replicas notice at different moments, so for a few seconds two of them may use different shards for one
  key. Therefore invalidation goes to every shard that is up, and every entry has a TTL that bounds
  what is left (30 s balances, 300 s zombies).
- Logout revocations must survive a lost shard: they are written to the first **two** shards along the
  ring and looked up on both.
- A scope's entries are stored under a random *generation* token kept on the same shard.
  Invalidating deletes the token. A slow reader that read PostgreSQL before a write can only store
  its old value under the old token, which nobody reads any more.

## Redis Cluster: hash slots

Redis Cluster does **not** use consistent hashing. It has a fixed table of 16 384 slots:

```
slot = CRC16(key) mod 16384          key "{player:7}:balances" hashes only "player:7"
node = slots[slot]                   the table, gossiped between the nodes
```

The `mod` is by a constant, so a key's slot never changes; scaling means **reassigning slots**.

| | Ours: consistent hashing in the client | Redis Cluster: hash slots |
|---|---|---|
| Mapping | `md5` on a ring → first point clockwise. *Computed*; needs only the list of shards | `CRC16 mod 16384` → slot → node. The slot is computed, its node is *looked up* in a table that is state |
| Who knows the map | Each client. The servers are plain, independent Valkeys | The servers, by gossip on the cluster bus; clients cache the table |
| Wrong guess | Cannot be told: the server just answers "miss" | `MOVED slot host:port` (permanent) or `ASK` (during migration) redirects the client |
| Adding a node | Automatic: about `1/(N+1)` of the keys belong to it at once, **cold** (misses) | Nothing moves until an operator reshards; `redis-cli --cluster reshard` migrates the **data**, key by key (or whole slots in newer versions), without misses |
| Balance | Statistical, depends on the virtual nodes | Exact by slot count (16384/N each), and chosen by the operator: a heavy node can be given fewer |
| Granularity | Whatever the points give; a node's arcs cannot be chosen | One slot (1/16384) can be moved by hand |
| A node dies | Clients skip it; its keys go clockwise and are refilled; its data is lost | Its replica is elected by the other masters and takes its slots, data included; without a replica the slots are down (`cluster-require-full-coverage` stops the whole cluster by default) |
| Replication | None (we write revocations twice ourselves) | Built in, asynchronous: an acknowledged write can still be lost in a failover |
| Split brain | Each client decides alone who is up, so they can disagree for seconds | Majority of masters decides; a minority stops accepting writes. Needs at least 3 masters |
| Multi-key operations | Only by choosing the same ring key (our scope) | Only within one slot; `{hash tags}` put keys together |
| Cost | A sorted array per client; `O(log(N·vnodes))` per key | A table lookup; a second port and gossip per node, ≥ 6 containers for 3 masters with replicas |

**Why ours is the ring.** The data is a cache: cold keys after scaling are acceptable, losing a shard's data
is acceptable, and three independent 32 MB containers without a cluster bus, elections or resharding
are the least that can break. Redis Cluster pays off where the data itself must survive scaling and
failures, that is, when Redis is a database. Its slots are the better design there because migrating
needs an explicit, agreed unit that is owned by exactly one node at any time, which a purely
computed mapping cannot express.

Others: Memcached clients (ketama), Cassandra and DynamoDB use rings with virtual nodes as we do.
Rendezvous hashing (highest `hash(key, node)` wins) moves as few keys without any ring, at `O(N)` per key.
Jump hash is smaller and more even still, but can only add or remove the *last* node, so it cannot
drop the one that died.

## See it

```
curl -H 'X-Internal-Key: changeme' 'localhost:8080/internal/cache?key=resource:player:1'  # owner, order
curl -i -H 'X-Internal-Key: changeme' localhost:8080/resources/players/1                  # X-Cache, X-Cache-Shard
docker compose stop redis-1                                                               # its keys go clockwise
```
