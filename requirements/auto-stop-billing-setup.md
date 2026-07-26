# Auto Stop Billing extension setup (`oneone-3adb5`)

This runbook installs and configures the [Auto Stop Services](https://github.com/deep-rock-development/auto-stop-firebase-ext) Firebase extension so the project **removes its billing account** when a Google Cloud budget threshold is reached. That stops new charges from accruing if usage spikes.

**Project:** `oneone-3adb5`  
**Extension instance:** `auto-stop-billing`  
**Pub/Sub topic:** `ext-firebase-trigger-auto-stop`  
**Functions region:** `asia-southeast1` (matches Realtime Database)

## What this does (and does not do)

When triggered, the extension **detaches billing from the project**. All paid services stop immediately (RTDB, Storage, Cloud Functions, FCM, etc.). Data is preserved but inaccessible until you manually re-attach billing.

**Important caveats:**

- Google Cloud cost reporting is delayed. You may spend **above** your budget before the alert fires.
- This is a blunt instrument — best for dev/staging or as a last-resort safety net, not a substitute for Firestore/RTDB security rules and quotas.
- Recovery is manual: re-link the billing account in GCP Console when you are ready.

## Repo files already prepared

| File | Purpose |
| --- | --- |
| `firebase.json` | Registers extension instance `auto-stop-billing` |
| `extensions/auto-stop-billing.env` | Extension parameters |

Current parameters:

```env
TOPIC_NAME=ext-firebase-trigger-auto-stop
BUDGET_STOP_THRESHOLD_PERCENT=1.0
DISABLE_BILLING=true
LOCATION=asia-southeast1
```

- `BUDGET_STOP_THRESHOLD_PERCENT=1.0` means stop at **100%** of the budget. Use `0.9` to stop at 90% if you want an earlier safety margin.
- `DISABLE_BILLING=true` is the recommended stop strategy for maximum cost protection.

## Step 1 — Re-authenticate Firebase CLI

The CLI credentials on this machine are expired. In your terminal:

```sh
cd /Users/user91/Desktop/Work/one-one
firebase login --reauth
firebase use oneone-3adb5
```

Verify:

```sh
firebase projects:list
```

## Step 2 — Deploy the extension

```sh
cd /Users/user91/Desktop/Work/one-one
firebase deploy --only extensions --project=oneone-3adb5
```

Review the prompts. The deploy creates:

- Cloud Functions `onInstallExtension` and `stopTriggered`
- Pub/Sub topic `ext-firebase-trigger-auto-stop`
- Extension service account `ext-auto-stop-billing@oneone-3adb5.iam.gserviceaccount.com`

After deploy, confirm in [Firebase Console → Extensions](https://console.firebase.google.com/project/oneone-3adb5/extensions).

### Troubleshooting: `artifactregistry.repositories.list` / `403 PERMISSION_DENIED`

If deploy fails while creating Cloud Functions with:

```txt
Unable to retrieve the repository metadata for .../repositories/gcf-artifacts.
Ensure that the Cloud Functions service account has ... 'roles/artifactregistry.reader'.
```

This project has not deployed Cloud Functions in that region before, so the default Cloud Functions service accounts need Artifact Registry read access. Grant the role, wait ~1 minute, then redeploy:

```sh
gcloud projects add-iam-policy-binding oneone-3adb5 \
  --member="serviceAccount:service-253584567538@gcf-admin-robot.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"

gcloud projects add-iam-policy-binding oneone-3adb5 \
  --member="serviceAccount:253584567538-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"

firebase deploy --only extensions --project=oneone-3adb5
```

Console alternative: [GCP IAM](https://console.cloud.google.com/iam-admin/iam?project=oneone-3adb5) → grant **Artifact Registry Reader** to both principals above.

## Step 3 — Grant billing manager to the extension service account

The extension must detach billing when triggered. In [GCP IAM](https://console.cloud.google.com/iam-admin/iam?project=oneone-3adb5):

1. Click **Grant access**.
2. **New principals:** `ext-auto-stop-billing@oneone-3adb5.iam.gserviceaccount.com`
3. **Role:** `Billing Account Manager` (`roles/billing.projectManager`)
4. Save.

Or with gcloud (replace `BILLING_ACCOUNT_ID` with your billing account ID, format `012345-6789AB-CDEF01`):

```sh
gcloud projects add-iam-policy-binding oneone-3adb5 \
  --member="serviceAccount:ext-auto-stop-billing@oneone-3adb5.iam.gserviceaccount.com" \
  --role="roles/billing.projectManager"
```

## Step 4 — Create a budget and connect it to Pub/Sub

In [GCP Billing → Budgets & alerts](https://console.cloud.google.com/billing/budgets):

1. **Create budget**.
2. **Scope:** billing account linked to `oneone-3adb5`.
3. **Amount:** set your monthly cap (e.g. `$25`, `$50`, `$100` — pick what you can tolerate).
4. Under **Manage notifications**, enable **Connect a Pub/Sub topic to this budget**.
5. In the topic picker:
   - Do **not** click **Create a topic** — the extension already created it during deploy.
   - Click **Switch project** and select **`oneone-3adb5`** (your Firebase project).
   - Select topic **`ext-firebase-trigger-auto-stop`** from the list.
6. Add alert thresholds that match your stop threshold:
   - If `BUDGET_STOP_THRESHOLD_PERCENT=1.0`, add a **100%** threshold (actual spend).
   - If using `0.9`, add a **90%** threshold.
7. Save the budget.

If the console cannot link the topic, grant the billing service account publish access (billing account `Firebase Payment`):

```sh
gcloud pubsub topics add-iam-policy-binding ext-firebase-trigger-auto-stop \
  --project=oneone-3adb5 \
  --member="serviceAccount:service-0136C7-42CC81-1A12A9@gcp-sa-billing-budgets.iam.gserviceaccount.com" \
  --role="roles/pubsub.publisher"
```

Then retry linking the topic in the budget editor.

### Troubleshooting: "Select a project to list topics" / cannot create topic

The budget UI shows **Create a topic** disabled when you lack `pubsub.topics.create`. You do **not** need that permission — the extension already created `ext-firebase-trigger-auto-stop`. Use **Switch project** → `oneone-3adb5` → pick the existing topic.

Firebase Console alternative: **Project settings → Usage and billing → Details & settings → Set budget alert** — then still link the same Pub/Sub topic in GCP.

## Step 5 — Test safely (optional)

Publish a **test** message that does not trigger shutdown:

```sh
gcloud pubsub topics publish ext-firebase-trigger-auto-stop \
  --project=oneone-3adb5 \
  --message='{"extensionTest": true}'
```

Check logs in [Cloud Logging](https://console.cloud.google.com/logs?project=oneone-3adb5) for the `stopTriggered` function. A test message should log without removing billing.

**Do not** publish a real budget alert JSON unless you intend to detach billing.

## Step 6 — Monitor

- [GCP Billing reports](https://console.cloud.google.com/billing)
- [Firebase Usage](https://console.firebase.google.com/project/oneone-3adb5/usage)
- Cloud Functions logs for `ext-auto-stop-billing`

## Recovery after billing is removed

1. [GCP Billing → Account management](https://console.cloud.google.com/billing/linkedaccount)
2. Select project `oneone-3adb5`
3. **Link a billing account** again
4. Verify RTDB, Storage, and backend services resume

## Changing the budget or threshold later

1. Edit `extensions/auto-stop-billing.env` if you change `BUDGET_STOP_THRESHOLD_PERCENT` or `TOPIC_NAME`.
2. Redeploy: `firebase deploy --only extensions --project=oneone-3adb5`
3. Update the GCP budget alert thresholds to match.

## Estimated extension cost

Roughly **$0.01/month** for the extension itself, plus normal Cloud Functions / Pub/Sub usage within free tiers for typical alert volume.
