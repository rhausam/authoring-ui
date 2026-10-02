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
Snowstorm ──► Classification Service :8089 ──► RF2 release zip (previousPackage)
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
| [Snowstorm](https://github.com/IHTSDO/snowstorm) | built jar with [`patches/snowstorm-11.0.0-export-module-filter.patch`](patches/) applied (see below), default `~/git-repo/snowstorm/target/snowstorm-11.0.0.jar` |
| [Authoring Services](https://github.com/IHTSDO/authoring-services) | built jar with [`patches/authoring-services-10.0.1-local-fixes.patch`](patches/) applied (see below), default `~/git-repo/authoring-services/target/authoring-services-10.0.1.jar` |
| [Classification Service](https://github.com/IHTSDO/classification-service) | built jar, default `~/git-repo/classification-service/target/classification-service-10.0.1.jar` |
| [sct-browser-frontend](https://github.com/IHTSDO/sct-browser-frontend) | optional, for the UI's **TS Browser** link: cloned to `~/git-repo/sct-browser-frontend` and built (see below) |
| [snomed-drools-rules](https://github.com/IHTSDO/snomed-drools-rules) | cloned to `~/git-repo/snomed-drools-rules`; Snowstorm runs these when the UI saves a concept |
| SNOMED CT RF2 release | an Edition package (International, or e.g. AU/US which include International) |

Paths and ports can be changed in `env.local.sh` (gitignored), for example:

```bash
JAVA_25=/Library/Java/JavaVirtualMachines/liberica-jdk-25.jdk/Contents/Home/bin/java
SNOWSTORM_JAR=$HOME/src/snowstorm/target/snowstorm-11.0.0.jar
RF2_RELEASE_ZIP=$HOME/Downloads/SnomedCT_InternationalRF2_PRODUCTION_20260901T120000Z.zip
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

   **Snowstorm 11.0.0** needs one fix too, for classification of extension-module
   content. Its RF2 export kept the module dependency refset's module filter for every
   refset exported after it. On a `MAIN` code system that drops OWL axioms in
   non-International modules (e.g. AU) from the classification delta, so classification
   finds no changes. This is fixed upstream on `develop` (85780b81, MAINT-2903) but not
   yet released; the patch is a backport:

   ```bash
   cd ~/git-repo/snowstorm
   git am ~/git-repo/authoring-ui/local-dev/patches/snowstorm-11.0.0-export-module-filter.patch
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

   It also symlinks `RF2_RELEASE_ZIP` (set in `env.sh`, the release you loaded) into
   the Classification Service release store and sets it as `MAIN`'s `previousPackage`.
   Classification sends the task's changes as a delta, and the service classifies
   them together with that release. So when you load a different release, update
   `RF2_RELEASE_ZIP` and run `seed.sh` again.
   Snowstorm generates identifiers itself, so they are unique only within this
   local instance; don't distribute content authored here.

## TS Browser

The UI's **TS Browser** link opens `/browser/`. The gateway serves it from a built
checkout of [sct-browser-frontend](https://github.com/IHTSDO/sct-browser-frontend)
(`BROWSER_DIR` in `env.sh`). That checkout talks to the same Snowstorm through the
gateway, as the logged-in user, and its Project and Task selectors browse task branches.
To set it up:

```bash
git clone https://github.com/IHTSDO/sct-browser-frontend.git ~/git-repo/sct-browser-frontend
cd ~/git-repo/sct-browser-frontend
nvm use 20
CYPRESS_INSTALL_BINARY=0 npm install
npx grunt        # builds internal-libs/ and css/snomed-interaction-components.min.css
```

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

Classifying a task runs the whole edition through ELK: about 70 seconds for the AU
Edition on an M3, with a 12 GB heap for the Classification Service. Review the results
and save them from the task's Classification view.

To save the results, hover over the green bell icon in the left icon column of the task
editor, choose **View Classification**, then click **Accept Classification Results** in the
report's header. Only the task's author sees that button.

### Other reasoners

The Classification Service loads the reasoner by its OWL API `OWLReasonerFactory` class
name, which Snowstorm passes as `reasonerId` (default
`org.semanticweb.elk.owlapi.ElkReasonerFactory`). Another reasoner must be built for
OWL API 4 (the service bundles 4.1.3) and be on the service's class path.

`start.sh` does this for [Konclude](https://github.com/konclude/Konclude) when
`KONCLUDE_PLUGIN_JAR` (see `env.sh`) points at a built Protege plug-in jar. Use a release
build kept at a stable path, not a development build directory: test runs overwrite those
with whatever branch is checked out. On each start it
copies the jar into `local-dev/data/classification-service/reasoners/`, extracts the native
library, and starts the service with the jar on the class path. Restart the service
(`stop.sh` / `start.sh`) to pick up a new plug-in build.

To choose a reasoner:

- **For one classification**, start it through Snowstorm:

  ```bash
  curl -X POST -H 'Cookie: local-ims=author1' \
    'http://localhost:9100/snowstorm/snomed-ct/MAIN/AUDEMO/AUDEMO-1/classifications?reasonerId=com.konclude.owlapi.KoncludeReasonerFactory'
  ```

  The result shows up in the task's bell menu like any other. Refresh the page, because no
  completion notification is sent.

- **For the UI's Classify button**, set `REASONER_ID=com.konclude.owlapi.KoncludeReasonerFactory`
  in `local-dev/env.local.sh` and restart the gateway. It adds that `reasonerId` to every
  classification request that doesn't name a reasoner.

On the AU Edition, Konclude infers the same hierarchy as ELK, in about 285 s against ELK's 70 s:
22 s to create the reasoner, 81 s of reasoning, and 131 s for the toolkit to read the hierarchy
back through the reasoner API.

To try the review workflow, create a task as `author1`, submit it for review,
then log out (user menu) and log in as `reviewer1`.

## What isn't available locally

These features call services that aren't part of this stack, so they show errors
or empty results: launching other platform apps, RVF
validation, the authoring acceptance gateway, templates, release notes, reporting,
traceability, CRS and spell check. The gateway answers `503` for those paths.
