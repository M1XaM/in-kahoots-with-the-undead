## Kahoot With Undead

A university-themed survival game built as a microservices system. Players wake up in FAF Cab
during a zombie apocalypse and must scavenge resources, build up their base, and fend off zombies —
including Professor Zombies, who force a pop quiz before letting you past. Passing exams unlocks new
wings of the university to explore, tying academic progress directly to survival progress.

[![player-service](https://img.shields.io/docker/v/timurcravtov/player-service?sort=semver&label=player-service&color=2496ED&logo=docker&logoColor=white)](https://hub.docker.com/r/timurcravtov/player-service)
[![game-service](https://img.shields.io/docker/v/timurcravtov/game-service?sort=semver&label=game-service&color=2496ED&logo=docker&logoColor=white)](https://hub.docker.com/r/timurcravtov/game-service)
[![exam-service](https://img.shields.io/badge/exam--service-v--.--.---red?logo=docker&logoColor=white)](https://hub.docker.com/r/timurcravtov/exam-service)
[![world-service](https://img.shields.io/badge/world--service-v--.--.---red?logo=docker&logoColor=white)](https://hub.docker.com/r/timurcravtov/world-service)
[![zombie-service](https://img.shields.io/badge/zombie--service-v--.--.---red?logo=docker&logoColor=white)](https://hub.docker.com/r/timurcravtov/zombie-service)
[![resource-service](https://img.shields.io/badge/resource--service-v--.--.---red?logo=docker&logoColor=white)](https://hub.docker.com/r/timurcravtov/resource-service)
[![base-service](https://img.shields.io/docker/v/mixam052/kahoots-base-service?sort=semver&label=base-service&color=2496ED&logo=docker&logoColor=white)](https://hub.docker.com/r/mixam052/kahoots-base-service)
[![crafting-service](https://img.shields.io/docker/v/mixam052/kahoots-crafting-service?sort=semver&label=crafting-service&color=2496ED&logo=docker&logoColor=white)](https://hub.docker.com/r/mixam052/kahoots-crafting-service)

[![player-service postman](https://img.shields.io/badge/player--service-postman-FF6C37?logo=postman&logoColor=white)](docs/postman/player-service)
[![game-service postman](https://img.shields.io/badge/game--service-postman-FF6C37?logo=postman&logoColor=white)](docs/postman/game-service)
[![exam-service postman](https://img.shields.io/badge/exam--service-no--docs-red?logo=postman&logoColor=white)](docs/postman/exam-service)
[![world-service postman](https://img.shields.io/badge/world--service-no--docs-red?logo=postman&logoColor=white)](docs/postman/world-service)
[![zombie-service postman](https://img.shields.io/badge/zombie--service-no--docs-red?logo=postman&logoColor=white)](docs/postman/zombie-service)
[![resource-service postman](https://img.shields.io/badge/resource--service-no--docs-red?logo=postman&logoColor=white)](docs/postman/resource-service)
[![base-service postman](https://img.shields.io/badge/base--service-postman-FF6C37?logo=postman&logoColor=white)](docs/postman/base-service)
[![crafting-service postman](https://img.shields.io/badge/crafting--service-postman-FF6C37?logo=postman&logoColor=white)](docs/postman/crafting-service)


## Architecture

![Architecture diagram](docs/architecture.png)

- **Player**: identity, auth, profiles, XP/levels, inventory, trading
- **Game**: sessions, day/night cycle, timed actions, zombie encounters
- **Exam**: exam generation, grading, academic history, achievements
- **World**: campus map: wings, rooms, resource nodes, spawn points
- **Zombie**: zombie type definitions, stats, abilities
- **Resource**: per-player resource balances and the gather/spend economy
- **Base**: what players have built: base level, facilities, barricades
- **Crafting**: recipes and crafting, delivering items into Player's inventory

Game orchestrates a session by calling World, Zombie and Exam over REST; Resource, Base and
Crafting react to what Game reports via async events, and publish their own events (level-ups,
exam results, wing unlocks) for services that depend on them. See the [Communication
Contract](docs/communication.md) for the full endpoint and event contract.

## Running

`docker-compose.yml` brings up every published service together, each with its own Postgres
instance (one DB per service, no shared tables), pulling images from Docker Hub — it never builds
from a service's Dockerfile.

Requirements: Docker with Compose v2, and the service ports below free on your machine.

```
cp .env.example .env   # adjust credentials/tags if needed
docker compose up
```

| Service | URL |
|---|---|
| Player | http://localhost:8081 |
| Game | http://localhost:8082 |
| Base | http://localhost:8087 |
| Crafting | http://localhost:8088 |

### Player Service

- **Image:** [`timurcravtov/player-service`](https://hub.docker.com/r/timurcravtov/player-service),
  version set by `PLAYER_SERVICE_TAG` (default `latest`).
- **Needs:** its own Postgres (`player-db`, started by compose); password defaults to `qwerty`, override with `PLAYER_POSTGRES_PASSWORD`.
- **Talks to:** nobody synchronously. It issues the login cookie and publishes the JWKS the other
  services use to verify it.
- **Try it:** Postman collection in [`docs/postman/player-service`](docs/postman/player-service).

### Game Service

- **Image:** [`timurcravtov/game-service`](https://hub.docker.com/r/timurcravtov/game-service),
  version set by `GAME_SERVICE_TAG` (default `latest`).
- **Needs:** its own Postgres (`game-db`, started by compose); password defaults to `qwerty`, override with `GAME_POSTGRES_PASSWORD`.
- **Talks to:** Player, World, Zombie, Exam, Resource and Base. Until they run, starting a
  session or a timed action that depends on them will fail; creating lobbies works on its own.
- **Try it:** Postman collection in [`docs/postman/game-service`](docs/postman/game-service).
  Log in through the Player collection first, since Game authenticates with the login cookie.

### Base Service

- **Image:** [`mixam052/kahoots-base-service`](https://hub.docker.com/r/mixam052/kahoots-base-service),
  version set by `BASE_SERVICE_TAG` (currently `0.1.0`).
- **Needs:** its own Postgres (`base-db`, started by compose); password defaults to `qwerty`, override with `BASE_POSTGRES_PASSWORD`.
- **Talks to:** Resource, World and Player. Until they run, spending endpoints (upgrades,
  barricades, Kiki) return `503 SERVICE_UNAVAILABLE`; reading and creating bases work on their own.
- **Try it:** Postman collection in [`docs/postman/base-service`](docs/postman/base-service).

### Crafting Service

- **Image:** [`mixam052/kahoots-crafting-service`](https://hub.docker.com/r/mixam052/kahoots-crafting-service),
  version set by `CRAFTING_SERVICE_TAG` (currently `0.1.0`).
- **Needs:** its own Postgres (`crafting-db`, started by compose); password defaults to `qwerty`, override with `CRAFTING_POSTGRES_PASSWORD`.
  Recipes start empty; add them with `POST /crafting/recipes`.
- **Talks to:** Resource and Player. Until they run, crafting returns `503 SERVICE_UNAVAILABLE`;
  recipes, availability and events work on their own.
- **Try it:** Postman collection in [`docs/postman/crafting-service`](docs/postman/crafting-service).

## GitHub Workflow

- **Branches**: `main` is protected: no direct pushes, merges only through a reviewed PR, CI must
  pass. `dev` is the integration branch everyone works off; feature work branches off `dev`
  and merges back into it, and `dev` is merged into `main` for releases.
- **Naming**: `feature/<short-description>`, `fix/<short-description>`, `chore/<short-description>`
  (e.g. `feature/resource-reservations`).
- **Commits**: follow [Conventional Commits](https://www.conventionalcommits.org):
  `type(scope)!: description`, where `(scope)` and `!` are optional. Use the imperative mood,
  lowercase, no trailing period (e.g. `feat(auth): add login endpoint`,
  `fix(db): correct migration order`, `feat(auth)!: change token format`).
  - Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`, `build`, `perf`.
  - Scope: the module or area touched, such as `auth`, `inventory` or `session`.
  - `!` marks a breaking API/event change and describes it in the commit body.
  - The release workflow reads these subjects to pick the version: `!` bumps `MAJOR`, `feat` bumps
    `MINOR`, anything else bumps `PATCH`. Because `dev` uses rebase merges, every commit in a PR
    reaches history as written, so each one must follow the format, not just the PR title.
  - The `Commit message check` action validates every commit in PRs into `dev` and `main`. Merge
    commits (e.g. `Merge branch 'main' into dev`) are skipped.
- **Merging**: into `dev`, use rebase and merge (linear history, each commit is kept). Into
  `main`, use a merge commit so each release is a single visible merge point. Squash merge is not
  used. Requires 1 approval and a passing CI run before the merge button unlocks.
- **PR content**: what changed and why, which service(s) it touches, how it was tested, and any
  follow-up work left out of scope. Linked to the relevant task/issue.
- **Auto draft PR**: the `Auto draft PR` workflow (`.github/workflows/auto-draft-pr.yml`) opens a
  draft PR into `dev` on the first push of any new branch, titled `Draft: <latest commit subject>`.
  It assigns the pusher, requests review from the rest of the team and Copilot, and fills the body
  with an AI summary of the commits and diff (via GitHub Models, with a static fallback).
- **Draft title guard**: the `PR title check` workflow (`.github/workflows/pr-title-check.yml`)
  fails while the PR title starts with `Draft`, so the author must rename the PR before it can
  merge. It only blocks merging once `no-draft-title` is a required status check in branch
  protection, and "Allow GitHub Actions to create pull requests" must be enabled in repo settings.
- **Test coverage**: new logic needs tests before merge; CI fails the build below the coverage
  threshold. Reviewers can ask for more coverage on a case-by-case basis.
- **Versioning**: semantic versioning per service (`MAJOR.MINOR.PATCH`), tagged on `main` at each
  release. Breaking API/event changes bump `MAJOR`.

## Documentation

- [Technologies](docs/technologies.md): tech stack per service and the trade-offs behind each choice.
- [Communication Contract](docs/communication.md): data ownership, endpoints and event payloads across services.
