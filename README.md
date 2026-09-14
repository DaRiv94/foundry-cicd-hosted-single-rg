# Hosted agent CI/CD, single resource group (lightweight topology)

This project promotes a Microsoft Foundry hosted agent from dev to test to prod when all three environments live inside ONE Foundry project. The agent is your own code: `agent/main.py` runs inside a container on Foundry Agent Service and serves the Responses protocol. It is a Frankies Bakery customer service agent that reads `agent/instructions.md`, with no tools.

The three environments are three hosted agents in the same project, told apart by a name suffix. Every promotion creates a new immutable version of the agent for that environment from the same container image. Prod is pinned to the version that passed the gate.

```
rg-ais-eus-hasingle                      one resource group
  msf-ais-eus-hasingle                   Microsoft Foundry account (keyless, Entra only)
    chat-model                           gpt-5-nano deployment, same name in every environment
    prj-ais-eus-hasingle                 Foundry project
      frankies-bakery-support-dev        versions 1, 2, 3 ...   endpoint serves the latest version
      frankies-bakery-support-test       versions 1, 2, 3 ...   the evaluation gate runs here
      frankies-bakery-support-prod       versions 1, 2, 3 ...   endpoint PINNED to the promoted version
  acraiseushasingle                      container registry: one image per commit, shared by all three agents
  id-ais-eus-hasingle-cicd               managed identity the pipeline signs in as
```

Zero secrets. GitHub Actions signs in to Azure with OpenID Connect as the managed identity. The Foundry account has local auth disabled and the registry has no admin user, so there is no key to leak.

## What is different from a prompt agent

A prompt agent is a definition: a model name plus instructions. A hosted agent is a container image plus settings. That adds exactly these things to the project:

- `agent/main.py`, `agent/requirements.txt`, `agent/Dockerfile`: the code and how to package it.
- A container registry in `infra/main.bicep`, and a role assignment so the Foundry project can pull from it.
- `scripts/2_build_image`: one more step between infra and deploy. The build runs inside the registry, so you do not need Docker on your machine.
- Two more roles for the pipeline identity. Foundry Owner cannot create a registry or grant the pull role, so the identity also gets Contributor and Role Based Access Control Administrator on the resource group.
- A wait. A new version pulls the image and starts a sandbox before it reports active, which takes a few minutes. The deploy script polls for it.

Everything else is the same: the three GitHub Environments, the reusable stage, the evaluation gate, the pin, the rollback.

## How promotion works

| Stage | Trigger | What runs | Gate |
|---|---|---|---|
| dev | push to any branch except `main` | deploy infra, build the image tagged with the commit sha, create a new agent version, smoke test | none |
| test | push to `main` (job 2 of the Release run) | deploy infra, confirm the image exists, new version from the same image, smoke test, evaluation gate | 6-row evaluation, 80 percent must pass |
| prod | push to `main` (job 3 of the Release run) | wait for the reviewer, deploy infra, confirm the image exists, new version, pin the endpoint, smoke test the pin | a person approves |

The Release run moves the same commit through dev, test, and prod. The image is built once, in the dev job, and test and prod deploy the identical bytes. The prod job waits because the `prod` GitHub Environment has a required reviewer. The evaluation gate blocks prod because the prod job declares `needs: test`.

## Prerequisites

Azure

- A subscription where you can create resource groups and role assignments.
- Quota for `gpt-5-nano` GlobalStandard in East US: 10K tokens per minute for the one account.
- East US, or another region where hosted agents are available.

Local machine

- Azure CLI 2.80 or later with Bicep (`az bicep upgrade`).
- GitHub CLI (`gh auth login` with the `repo` and `workflow` scopes).
- Python 3.12 or later.
- PowerShell 7 or Bash. Every script has both.
- No Docker. The registry builds the image.

GitHub

- A public repo. Required reviewers on Environments are free only on public repos.

## Files in this folder

- `agent/main.py` is the agent. It builds an Agent Framework agent on `FoundryChatClient` and serves it with `ResponsesHostServer` on port 8088.
- `agent/instructions.md` is what the agent reads at startup. Edit this file to change the agent, then promote it.
- `agent/requirements.txt` and `agent/Dockerfile` package the agent. The platform injects the project endpoint into the container; the model deployment name is the one setting the deploy script passes in.
- `evals/bakery-eval-set.jsonl` holds six questions with the phrase each answer must contain.
- `infra/main.bicep` creates the Foundry account, the project, the `chat-model` deployment, the container registry, and two role assignments. Deployed once, because all three environments share it.
- `scripts/0_prepare` creates the resource group and grants you Foundry Owner on it.
- `scripts/0b_pipeline_identity` creates the managed identity, its three federated credentials, its three roles, the GitHub Environments, and the variables.
- `scripts/1_deploy_infra` runs the Bicep deployment. The pipeline runs this same file.
- `scripts/2_build_image` builds the image in the registry for dev, or checks that the tag exists for test and prod.
- `scripts/3_deploy_agent.py` creates a new immutable version of the hosted agent for one environment and waits for it to become active.
- `scripts/4_smoke_test.py` asks the agent endpoint one question and fails on an empty answer. It retries, because the first call after a deploy starts a sandbox.
- `scripts/5_evaluate.py` runs the evaluation gate against one version and exits 1 below 80 percent.
- `scripts/6_pin_version.py` routes 100 percent of the prod endpoint to one version. Rollback uses the same script.
- `scripts/99_teardown` deletes the resource group.
- `.github/workflows/deploy-stage.yml` is the one reusable stage. `dev.yml` and `release.yml` call it and pass the commit sha as the image tag.
- `adding-capabilities.md` explains what changes when you add web search, file search, Azure AI Search, an MCP server, or code execution.

## Set up

Windows (PowerShell)

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
az login
```

Mac / Linux (Bash)

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
az login
```

Open `.env` and replace the two placeholders: your subscription id and, for later, your GitHub repo as `owner/name`. Every script refuses to run while a placeholder is still there. The two keys at the bottom are only for running the agent code on your machine.

## Run the agent code on your machine

Do this once so you know what the container does. It needs the model deployment, so run `0_prepare` and `1_deploy_infra` first (next section), then come back.

Windows (PowerShell)

```powershell
pip install -r agent\requirements.txt
python agent\main.py
# in a second terminal
Invoke-RestMethod -Method Post -Uri http://localhost:8088/responses -ContentType "application/json" -Body '{"input":"What time do you open on Saturday?","stream":false}' | Select-Object -ExpandProperty output | Where-Object type -eq message | ForEach-Object { $_.content.text }
```

Mac / Linux (Bash)

```bash
pip install -r agent/requirements.txt
python agent/main.py
# in a second terminal
curl -s -X POST http://localhost:8088/responses -H "Content-Type: application/json" -d '{"input":"What time do you open on Saturday?","stream":false}'
```

The server prints its OpenTelemetry setup, then answers in about ten seconds the first time. `GET http://localhost:8088/readiness` returns 200 while it runs. Stop it with Ctrl+C. In the cloud, the platform runs this same process and calls the same two URLs.

## Run it locally first

Do the whole promotion by hand once. It is the same sequence the pipeline runs, so when the pipeline runs later you already know every step. Pick a tag such as `v1` for the image. The pipeline uses the commit sha instead.

Windows (PowerShell)

```powershell
.\scripts\0_prepare.ps1
.\scripts\1_deploy_infra.ps1 -Env dev

# dev: build once, deploy
.\scripts\2_build_image.ps1 -Env dev -Tag v1
python scripts\3_deploy_agent.py --env dev --image-tag v1
python scripts\4_smoke_test.py --env dev

# test: same image, the gate runs here
.\scripts\2_build_image.ps1 -Env test -Tag v1
python scripts\3_deploy_agent.py --env test --image-tag v1
python scripts\4_smoke_test.py --env test
python scripts\5_evaluate.py --env test --agent-version 1

# prod: same image, pin, then prove the pin
.\scripts\2_build_image.ps1 -Env prod -Tag v1
python scripts\3_deploy_agent.py --env prod --image-tag v1
python scripts\6_pin_version.py --env prod --agent-version 1
python scripts\4_smoke_test.py --env prod
```

Mac / Linux (Bash)

```bash
./scripts/0_prepare.sh
./scripts/1_deploy_infra.sh dev

# dev: build once, deploy
./scripts/2_build_image.sh dev v1
python scripts/3_deploy_agent.py --env dev --image-tag v1
python scripts/4_smoke_test.py --env dev

# test: same image, the gate runs here
./scripts/2_build_image.sh test v1
python scripts/3_deploy_agent.py --env test --image-tag v1
python scripts/4_smoke_test.py --env test
python scripts/5_evaluate.py --env test --agent-version 1

# prod: same image, pin, then prove the pin
./scripts/2_build_image.sh prod v1
python scripts/3_deploy_agent.py --env prod --image-tag v1
python scripts/6_pin_version.py --env prod --agent-version 1
python scripts/4_smoke_test.py --env prod
```

What you see

- `1_deploy_infra` prints the project endpoint. It takes two to three minutes the first time and seconds after that.
- `2_build_image -Env dev` uploads the `agent` folder to the registry and builds there. About two minutes. For test and prod it only checks that the tag exists.
- `3_deploy_agent` prints `frankies-bakery-support-dev version 1 created from acraiseushasingle.azurecr.io/frankies-bakery-support:v1`, then a `status: creating` line every five seconds until `status: active`. Expect under a minute; the platform pulls the image and prepares the sandbox. A `status: failed` with `ImageError` means the project identity cannot pull from the registry (the AcrPull role assignment in Bicep is what allows it).
- `4_smoke_test` may print `attempt 1 failed` once while the sandbox starts, then the answer.
- `5_evaluate` polls for about two minutes, prints one line per question, then `Pass rate 6/6 = 100% (minimum 80%)` and `GATE PASSED`.
- `6_pin_version` prints which version the prod endpoint now serves.

Where to look in the Foundry portal: open the project, then Agents. You see three hosted agents. Open one and look at its versions, each with the image reference and the `git_sha` and `env` metadata. On the prod agent, the endpoint settings show the pinned version instead of "always use latest". In the Azure portal, the registry shows one repository with one tag per build.

## Wire up GitHub

1. Create a public repo and push this folder to its `main` branch.
2. Put the repo name in `.env` as `GITHUB_REPO=owner/name`.
3. Run the bootstrap script. It needs `az login` and `gh auth login`.

Windows (PowerShell)

```powershell
.\scripts\0b_pipeline_identity.ps1
```

Mac / Linux (Bash)

```bash
./scripts/0b_pipeline_identity.sh
```

It creates one managed identity in the resource group with three federated credentials, one per GitHub Environment. Each credential trusts only jobs that run inside that Environment, so the `prod` job is the only job that gets a token after a reviewer approves. The identity gets three roles on the resource group, and each one pays for one pipeline step: Contributor creates the registry and runs the build, Role Based Access Control Administrator writes the pull role for the project identity, and Foundry Owner creates the Foundry resources and the agent versions.

4. Wait about ten minutes for the role assignments to propagate, then push a change or start the Release workflow from the Actions tab. If the first run fails at the login step with "No subscriptions found", it was too early. Rerun it.

Federated credential subjects: GitHub issues an immutable subject for repos created after July 2026, `repo:OWNER@OWNER-ID/REPO@REPO-ID:environment:NAME`. The script reads both ids with `gh api` and builds that subject.

## The promotion loop

This is the loop a developer runs every day.

1. Create a branch and edit `agent/instructions.md` or `agent/main.py`. For example, change Saturday closing time from 6 PM to 5 PM.
2. Push the branch. The Dev workflow builds an image tagged with the commit sha, deploys a new version of `frankies-bakery-support-dev` from it, and smoke tests it.
3. Open a pull request and merge it.
4. The Release workflow starts on `main`: the dev job builds the merge commit's image and deploys it, then the test job deploys the same image as a test version and runs the evaluation gate, then the prod job waits.
5. Approve the prod job in the Actions tab. It creates the prod version from the same image, pins the endpoint to it, and smoke tests the pinned endpoint. The smoke test output shows the new closing time.

Nothing reaches prod without a passing gate on the exact image and a human approval. Note the difference from the prompt agent projects: here the promoted artifact is real bytes. The image built in the dev job is the image running in prod.

## Break the gate

See the gate do its job once.

1. On a branch, delete rule 3 from `agent/instructions.md` (the "I will connect you with a team member" sentence) and change the Sunday hours to "9 AM to 2 PM Sunday".
2. Merge it. The test job's evaluation step fails two of six rows, prints `Pass rate 4/6 = 67%`, exits 1, and the prod job never starts. Prod keeps serving the pinned version.
3. Restore both edits and merge. The gate passes and prod gets the fixed version.

The gate tolerates one miss on purpose, so a single wrong row passes at 83 percent. Six rows is small. With a real evaluation set you raise the row count and the threshold together.

## Rollback

Prod serves one pinned version. To go back, pin the previous one. The old image is still in the registry and the old version still references it.

Windows (PowerShell)

```powershell
python scripts\6_pin_version.py --env prod --agent-version 1
```

Mac / Linux (Bash)

```bash
python scripts/6_pin_version.py --env prod --agent-version 1
```

A pin cannot be removed, only re-pointed.

## Where a bigger gate would go

The gate is one deterministic substring check per row, so it needs no judge model. To add an LLM-judged criterion such as task adherence, deploy a judge model in Bicep and add a second entry to `testing_criteria` in `scripts/5_evaluate.py`. The pipeline does not change.

## Cost

Foundry accounts, projects, and agents cost nothing while idle. The registry is Basic tier, about five dollars a month. A hosted agent bills for sandbox compute (0.5 vCPU, 1 GiB here) only while a session is active, and a session ends fifteen minutes after its last request. Tokens are billed as usual.

## Teardown

Windows (PowerShell)

```powershell
.\scripts\99_teardown.ps1
```

Mac / Linux (Bash)

```bash
./scripts/99_teardown.sh
```

The script lists the resource group, asks you to type DELETE, and deletes it. The registry, the managed identity, and the role assignments live inside the group, so nothing is left behind in Azure. The GitHub repo and its Environments stay and cost nothing.

## When to use this topology

Use one project for all three environments when one small team owns the agent and cheap, fast setup matters more than isolation. One registry, one account, one identity. Every stage of every run deploys into the same account, so the stage workflow serializes them with a concurrency group; a second run waits for the first.

Do not use it when different teams need different access to dev and prod, when compliance needs separate audit trails per environment, or when prod needs its own capacity. Project `03-hosted-agent-multi-rg` shows the same agent with three resource groups and three registries.

I recommend this topology for learning hosted agents because you build one image and watch it run as three versions in one place. Move to three resource groups before the agent has real users.

## Adding capabilities

See `adding-capabilities.md` for what changes when you add web search, file search, RAG with Azure AI Search, an MCP server, or code execution to a hosted agent.
