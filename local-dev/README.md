# Local Authoring Platform stack

Runs the Authoring UI against your own Snowstorm and Authoring Services, with no
IHTSDO/IMS account, Jira, AWS or other hosted services. Intended for development,
demonstrations and testing on a single machine.

```
Browser ──► gateway.js :9100 ──┬─► grunt serve :9001            (the UI)
                               ├─► Authoring Services :8081     (/authoring-services/)
                               ├─► Snowstorm :8090              (/snowstorm/snomed-ct/)
                               └─  fake IMS: /local-login, /auth, /ims/*

Authoring Services ──► gateway ──► Snowstorm / fake IMS
Snowstorm ──► Elasticsearch :9200
Authoring Services ──► MariaDB/MySQL :3306 (ts_review)
Snowstorm ◄──► ActiveMQ :61616 ◄──► Authoring Services
```

The gateway does the job of the nginx + IMS front door in a real deployment. You
pick a user on its login page; it then adds the `X-AUTH-username`, `X-AUTH-roles`
and `X-AUTH-token` headers that Authoring Services and Snowstorm trust. Users and
their roles are in [`users.json`](users.json):

| User | Roles | Use |
|---|---|---|
| `admin` | `ihtsdo-sca-author`, `snowstorm-admin` | creating projects, Snowstorm admin |
| `author1` | `ihtsdo-sca-author` | authoring |
| `reviewer1` | `ihtsdo-sca-author` | reviewing another user's task |

**Never expose the gateway beyond localhost**: anyone who can reach it can act as any user.

## Prerequisites

| Component | Notes |
|---|---|
| Node 20 | `nvm use` in the repo root (see `.nvmrc`); `npm install` done |
| Java 25 | Snowstorm 11 and Authoring Services 10. Set `JAVA_25` if not at the asdf Temurin path in `env.sh` |
| Elasticsearch 8 | running on `localhost:9200` |
| MariaDB or MySQL | running on `localhost:3306` |
| ActiveMQ Classic | `brew install activemq` (started by `start.sh`) |
| [Snowstorm](https://github.com/IHTSDO/snowstorm) | built jar, default `~/git-repo/snowstorm/target/snowstorm-11.0.0.jar` |
| [Authoring Services](https://github.com/IHTSDO/authoring-services) | built jar with [`patches/authoring-services-10.0.1-local-fixes.patch`](patches/) applied (see below), default `~/git-repo/authoring-services/target/authoring-services-10.0.1.jar` |
| [snomed-drools-rules](https://github.com/IHTSDO/snomed-drools-rules) | cloned to `~/git-repo/snomed-drools-rules`; Snowstorm runs these when the UI saves a concept |
| SNOMED CT RF2 release | an Edition package (International, or e.g. AU/US which include International) |

Paths and ports can be changed in `env.local.sh` (gitignored), for example:

```bash
JAVA_25=/Library/Java/JavaVirtualMachines/liberica-jdk-25.jdk/Contents/Home/bin/java
SNOWSTORM_JAR=$HOME/src/snowstorm/target/snowstorm-11.0.0.jar
```

If you change a port, also update the URLs in `authoring-services.properties`.

## First-time setup

1. **Elasticsearch disk thresholds.** By default Elasticsearch stops allocating
   shards when the disk is 90% full, even with plenty of GB free. Indices then
   stay red and imports silently store nothing. On a dev machine use absolute values:

   ```bash
   curl -XPUT localhost:9200/_cluster/settings -H 'Content-Type: application/json' -d '{"persistent":{
     "cluster.routing.allocation.disk.watermark.low":"30gb",
     "cluster.routing.allocation.disk.watermark.high":"20gb",
     "cluster.routing.allocation.disk.watermark.flood_stage":"10gb"}}'
   ```

2. **Database.** Create the database and a user, and put the password in `local-dev/.secrets.env`:

   ```sql
   CREATE DATABASE ts_review CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   CREATE USER 'local'@'localhost' IDENTIFIED BY '<password>';
   CREATE USER 'local'@'127.0.0.1' IDENTIFIED BY '<password>';
   GRANT ALL ON ts_review.* TO 'local'@'localhost';
   GRANT ALL ON ts_review.* TO 'local'@'127.0.0.1';
   ```

   ```bash
   echo 'TS_REVIEW_DB_PASSWORD=<password>' > local-dev/.secrets.env
   ```

   Authoring Services creates its tables on first start.

3. **Build Authoring Services with the local fixes.** Version 10.0.1 can't create
   projects or tasks on a database built by its own migrations: the `Project` and
   `Task` collections lack `mappedBy`, so Hibernate expects join tables that don't
   exist. Project creation also re-creates the branch it has just created, because
   of a cached "not found" lookup. Both are fixed by the patch:

   ```bash
   cd ~/git-repo/authoring-services
   git apply ~/git-repo/authoring-ui/local-dev/patches/authoring-services-10.0.1-local-fixes.patch
   mvn -DskipTests package
   ```

4. **Load SNOMED CT into Snowstorm** (once; takes a while). Use the Snapshot package:

   ```bash
   java -Xms2g -Xmx6g -jar ~/git-repo/snowstorm/target/snowstorm-11.0.0.jar \
     --spring.config.additional-location=file:local-dev/snowstorm.properties \
     --delete-indices --import=/path/to/SnomedCT_Edition_SNAPSHOT.zip
   ```

   Wait for `Completed RF2 SNAPSHOT import` in the output, then stop it (Ctrl-C).

5. **Start everything and seed** permissions, branch metadata and a demo project:

   ```bash
   ./local-dev/start.sh
   ./local-dev/seed.sh
   ```

   `seed.sh` defaults to the Australian Edition: module `32506021000036107`, namespace
   `1000036`, the en-AU language refset, and the `common-authoring,au-authoring`
   validation rule groups. For other content override the variables listed at the
   top of the script.
   Snowstorm generates identifiers itself, so they are unique only within this
   local instance; don't distribute content authored here.

## Daily use

```bash
./local-dev/start.sh     # then open http://localhost:9100
./local-dev/status.sh
./local-dev/stop.sh      # leaves Elasticsearch and MariaDB running
```

Logs are in `local-dev/logs/`; Snowstorm and Authoring Services run from (and write
working files to) `local-dev/data/`. UI edits reload live as with plain `grunt serve`.

Saving a concept runs the Drools rules. The `common-authoring` group requires an FSN
and a preferred synonym in the **US English** language refset as well as en-AU, so set
the `us` acceptability to P as well as `au`.

To try the review workflow, create a task as `author1`, submit it for review,
then log out (user menu) and log in as `reviewer1`.

## What isn't available locally

These features call services that aren't part of this stack, so they show errors
or empty results: launching other platform apps; classification (needs
[classification-service](https://github.com/IHTSDO/classification-service)), RVF
validation, the authoring acceptance gateway, templates, release notes, reporting,
traceability, CRS and spell check. The gateway answers `503` for those paths.
