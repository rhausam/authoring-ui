# Local Authoring Platform stack

Runs the Authoring UI against your own Snowstorm and Authoring Services, with no
IHTSDO/IMS account, Jira, AWS or other hosted services. Intended for development,
demonstrations and testing on a single machine.

```
Browser ──► gateway.js :9100 ──┬─► grunt serve :9001                 (the UI)
                               ├─► Authoring Services :8081          (/authoring-services/)
                               ├─► Snowstorm :8090                   (/snowstorm/snomed-ct/)
                               ├─► Traceability Service :8085        (/authoring-traceability-service/)
                               ├─  TS Browser (static files)         (/browser/)
                               └─  fake IMS: /local-login, /auth, /ims/*

Authoring Services ──► gateway ──► Snowstorm / fake IMS
Snowstorm, Traceability Service ──► Elasticsearch :9200
Authoring Services ──► MariaDB/MySQL :3306 (ts_review)
Snowstorm ──► Classification Service :8089 ──► RF2 release zip (previousPackage)

ActiveMQ :61616 queues
  default.classification-service.status   Classification Service ──► Snowstorm
  default.authoring.classification.status Snowstorm ──► Authoring Services
  default.traceability                    Snowstorm ──► Traceability Service
```

The gateway does the job of the nginx + IMS front door in a real deployment. You
pick a user on its login page; it then adds the `X-AUTH-username`, `X-AUTH-roles`
and `X-AUTH-token` headers that Authoring Services, Snowstorm and the Traceability
Service trust. Users and their roles are in [`users.json`](users.json):

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
| Java 25 | the Java services. Set `JAVA_25` if not at the asdf Temurin path in `env.sh` |
| Elasticsearch 8 | running on `localhost:9200` |
| MariaDB or MySQL | running on `localhost:3306` |
| ActiveMQ Classic | `brew install activemq` (started by `start.sh`) |
| [Snowstorm](https://github.com/IHTSDO/snowstorm) | built jar with [`patches/snowstorm-11.0.0-export-module-filter.patch`](patches/) applied (see below), default `~/git-repo/snowstorm/target/snowstorm-11.0.0.jar` |
| [Authoring Services](https://github.com/IHTSDO/authoring-services) | built jar with [`patches/authoring-services-10.0.1-local-fixes.patch`](patches/) applied (see below), default `~/git-repo/authoring-services/target/authoring-services-10.0.1.jar` |
| [Classification Service](https://github.com/IHTSDO/classification-service) | built jar, default `~/git-repo/classification-service/target/classification-service-10.0.1.jar` |
| [Traceability Service](https://github.com/IHTSDO/traceability-service) | built jar, default `~/git-repo/traceability-service/target/authoring-traceability-service-6.0.0.jar` |
| [sct-browser-frontend](https://github.com/IHTSDO/sct-browser-frontend) | optional, for the UI's **TS Browser** link: cloned to `~/git-repo/sct-browser-frontend` and built (see below) |
| [snomed-drools-rules](https://github.com/IHTSDO/snomed-drools-rules) | cloned to `~/git-repo/snomed-drools-rules`; Snowstorm runs these when the UI saves a concept |
| SNOMED CT RF2 release | an Edition package (International, or e.g. AU/US which include International) |

Build each Java service with `mvn -DskipTests package` in its checkout.

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

## Daily use

```bash
./local-dev/start.sh     # then open http://localhost:9100
./local-dev/status.sh
./local-dev/stop.sh      # leaves Elasticsearch and MariaDB running
```

Logs are in `local-dev/logs/`; the Java services run from (and write working files to)
`local-dev/data/`. UI edits reload live as with plain `grunt serve`.

The status indicator in the UI's footer ("All Systems Operational" / "Service Under
Maintenance") is a widget for SNOMED International's public status page. It says nothing
about this local stack.

## Demo walkthrough

The full task lifecycle, with the steps that are easy to miss. Log in at
<http://localhost:9100>; to switch user, use **Logout** at the top right.

1. **Create a task** (`author1`). Dashboard → **New Task** in the left sidebar → title,
   project → **Create Task**. Click the task's name to open it; the task branch is
   created the first time it's opened.

2. **Edit a concept.** Search in the left panel, open a concept, change it and save
   (disk icon at the top right of the concept). Saving runs the Drools rules: the
   `common-authoring` group requires an FSN and a preferred synonym in the **US English**
   language refset as well as en-AU, so set `us` to **P** as well as `au`.

3. **Classify.** Click **Classify** in the task panel. While it runs, the task shows as
   locked ("Task branch is locked due to an ongoing rebase, promotion or classification").
   With ELK it takes about 70 seconds on the AU Edition.

4. **Accept the classification results.** This is not in the task panel: hover over the
   **green bell icon** (second icon in the narrow column at the far left) → **View
   Classification** → **Accept Classification Results** at the right of the report's
   green header. Only the task's author sees that button. If the report is empty, there
   is nothing to accept.

5. **Submit for review.** **Submit For Review** in the task panel. It checks that the
   classification is current, i.e. run after the last change; if you edit again,
   classify again first.

6. **Review** (`reviewer1`). Dashboard → **Review Tasks** in the left sidebar → click the
   task's **name** (the "Available" label is only a status) to open the review screen,
   which claims the review. Approve each concept under **To Review** with its green
   thumbs-up icon, then switch the toggle at the top right from "Review in Progress" to
   **Review Complete**.

7. **Promote the task** (`author1`). Open the task → **Promote This Task to the Project**.
   The task becomes read-only ("Task has been promoted. No further changes allowed.").

8. **Rebase another task.** Open another task of the same project: the **rebase icon**
   (circular arrows, "Pull new changes from project") in the left icon column is yellow
   when the task is behind its project. Click it; without conflicts it merges straight
   away.

9. **Promote the project** to `MAIN` from the project page. This puts the project's
   content into `MAIN` for good; Snowstorm has no simple undo, so on a stack you want to
   keep clean, skip this step or reload the release afterwards.

If the editor still shows a concept as it was before a change made elsewhere (another
tab, another user, the API), reload the page before saving, or the save will put the
old values back.

## Classification

Classifying a task runs the whole edition through the reasoner: about 70 seconds with
ELK for the AU Edition on an M3, with a 12 GB heap for the Classification Service.

Snowstorm gets classification status from the Classification Service over JMS
(`classification-service.job.status.use-jms` in `snowstorm.properties`), as SNOMED
International deployments do. Its default, polling, leaves the classification id empty
in the status it forwards to Authoring Services, which then never hears that a
classification finished: the UI keeps showing the task as locked.

### Other reasoners

The Classification Service loads the reasoner by its OWL API `OWLReasonerFactory` class
name, which Snowstorm passes as `reasonerId` (default
`org.semanticweb.elk.owlapi.ElkReasonerFactory`). Another reasoner must be built for
OWL API 4 (the service bundles 4.1.3) and be on the service's class path.

`start.sh` does this for [Konclude](https://github.com/konclude/Konclude) when
`KONCLUDE_PLUGIN_JAR` (see `env.sh`) points at a built Protege plug-in jar. Use a release
build kept at a stable path, not a development build directory: test runs overwrite those
with whatever branch is checked out. On each start it copies the jar into
`local-dev/data/classification-service/reasoners/`, extracts the native library, and
starts the service with the jar on the class path. Restart the service
(`stop.sh` / `start.sh`) to pick up a new plug-in build. Extra JVM options, such as
`-Dkonclude.taxonomyCache=false`, go in `CLASSIFICATION_JAVA_OPTS`.

To choose a reasoner:

- **For one classification**, start it through Snowstorm:

  ```bash
  curl -X POST -H 'Cookie: local-ims=author1' \
    'http://localhost:9100/snowstorm/snomed-ct/MAIN/AUDEMO/AUDEMO-1/classifications?reasonerId=com.konclude.owlapi.KoncludeReasonerFactory'
  ```

  The result shows up in the task's bell menu like any other. Refresh the page, because
  Authoring Services only notifies the UI about classifications it started itself.

- **For the UI's Classify button**, set `REASONER_ID=com.konclude.owlapi.KoncludeReasonerFactory`
  in `local-dev/env.local.sh` and restart the gateway. It adds that `reasonerId` to every
  classification request that doesn't name a reasoner.

On the AU Edition, Konclude infers the same hierarchy as ELK. With the release build of
master d5ddf4fc it takes about 120 s against ELK's 70 s (17 s to create the reasoner,
42 s of reasoning, 13 s to read the hierarchy back), and its native memory no longer
grows from one classification to the next.

## Traceability

The Traceability Service records every commit Snowstorm makes
(`authoring.traceability.enabled` in `snowstorm.properties`) in Elasticsearch indices
prefixed `trace-`. The UI reads it to list a task's changed concepts for review, and for
the promotion checks, the rebase status and concept history. Only changes made while it
is running are recorded: content changed before it was set up won't appear in a review
until it is changed again.

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

## The fake IMS

Besides the login page, the gateway answers the IMS calls the services make:

- `/auth` and `/ims/account`: the logged-in user (UI and Authoring Services)
- `/ims/user`, `/ims/group/user`: user lookups, e.g. for reviewer lists
- `/ims/authenticate`: the service-account login Authoring Services does before a lookup.
  Its IMS client names the session cookie after the first label of the IMS host
  (`dev-ims-ihtsdo` for `dev-ims.ihtsdotools.org`) and fails on a host without a dot, so
  `ims.url` uses `127.0.0.1` and the gateway answers with a `127-ims-ihtsdo` cookie.

## What isn't available locally

These features call services that aren't part of this stack, so they show errors
or empty results: launching other platform apps, RVF validation, the authoring
acceptance gateway, templates, release notes, reporting, CRS and spell check. The
gateway answers `503` for those paths.
