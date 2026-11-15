# Postgres 16 with Patroni: every node of a database cluster runs this image. Patroni starts
# Postgres, keeps the cluster's leader lock in etcd, promotes a replica when the primary is gone
# and turns a returning old primary into a replica (pg_rewind). Port 8008 is its REST API, which
# HAProxy polls (GET /primary, GET /replica) to route connections.
FROM postgres:16-alpine

# psycopg2 and psutil come prebuilt from Alpine, so pip compiles nothing
RUN apk add --no-cache python3 py3-psycopg2 py3-psutil \
    && apk add --no-cache --virtual .build py3-pip \
    && pip install --no-cache-dir --break-system-packages 'patroni[etcd3]==4.1.4' \
    && apk del .build

COPY patroni.yml /etc/patroni/patroni.yml
COPY entrypoint.sh post_init.sh /usr/local/bin/

USER postgres
EXPOSE 5432 8008
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
