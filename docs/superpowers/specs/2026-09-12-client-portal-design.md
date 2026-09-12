# Client Portal + Admin Panel Design

**Date:** 2026-09-12
**Status:** Approved, pending implementation plan

## Background

DevDesk is currently a single static page (`index.html`) with a 4-step
lead-capture wizard. On submit, the wizard POSTs to Formspree, which emails
the operator; the client gets no further visibility into their request
until they receive a quote by email.

This design adds:

1. A **client portal** where a client can log in (passwordless) and see the
   live status of their request(s).
2. An **admin panel** where the operator manages incoming requests
   (set status, quote price, quote date, notes) without digging through
   email.
3. Removal of Formspree — the wizard writes directly to a database instead.

## Goals

- Client can check request status without emailing/waiting.
- Operator has one place to see and update all requests instead of an
  inbox.
- No new hosting/build requirements — site stays a flat set of static
  HTML files, deployable the same way it is today.
- Minimal new infrastructure to operate and pay for, appropriate for a
  solo/small freelance operation at low volume.

## Non-goals

- No payment processing changes (DuitNow/TnG flow outside the app is
  unchanged).
- No multi-admin roles/permissions beyond a single `is_admin` flag.
- No automated test suite (matches the project's current state — plain
  HTML/JS, no build or test tooling).
- No password-based accounts.

## Architecture

Add a Supabase project (managed Postgres + Auth). The site remains static
and gains two new pages alongside the existing one:

- `index.html` — existing wizard, modified submit target only.
- `portal.html` — new. Client-facing status view.
- `admin.html` — new. Operator dashboard.

All three load `@supabase/supabase-js` from a CDN `<script>` tag and talk
to Supabase directly from the browser using the public (anon) API key.
There is no application server; Postgres Row Level Security (RLS) is the
only access-control layer. Hosting/deployment process is unchanged
(same static host, same repo).

## Data model

### `profiles`

| column     | type      | notes                                  |
|------------|-----------|-----------------------------------------|
| id         | uuid, PK  | equals `auth.users.id`                  |
| is_admin   | boolean   | default `false`; set manually by owner  |
| created_at | timestamptz | default `now()`                       |

One row per authenticated user, auto-created on first login (via a
Supabase Auth trigger, or lazily on first portal/admin visit). The
operator's own row gets `is_admin = true` set once, by hand, in the
Supabase table editor — no UI for granting admin.

### `requests`

| column       | type        | notes                                                        |
|--------------|-------------|---------------------------------------------------------------|
| id           | uuid, PK    | default `gen_random_uuid()`                                   |
| client_id    | uuid, null  | FK to `auth.users.id`; null until claimed (see below)          |
| email        | text        | required; submitted by client, used to claim/match             |
| name         | text        | required                                                       |
| service      | text        | wizard step 1 choice                                           |
| urgency      | text        | wizard step 3 choice                                           |
| details      | text        | wizard step 2 free text                                        |
| status       | text        | `submitted` \| `quoted` \| `in_progress` \| `delivered` \| `declined`; default `submitted` |
| quote_price  | numeric     | null until operator sets it                                    |
| quote_date   | date        | null until operator sets it (target delivery date)             |
| admin_notes  | text        | null; operator-only, not shown to client                       |
| created_at   | timestamptz | default `now()`                                                |
| updated_at   | timestamptz | default `now()`; bumped on update via trigger                  |

## Access control (RLS)

- **Insert on `requests`:** allowed for anyone (anon or authenticated) —
  this is the public wizard submission. No auth required to create a
  request.
- **Select on `requests`:** allowed when any of:
  - `client_id = auth.uid()`, or
  - `email = auth.jwt() ->> 'email'` (covers the window between
    submission and the client claiming the row on first login), or
  - the caller's `profiles.is_admin = true`.
- **Update on `requests`:**
  - Admin (`is_admin = true`): full update access (status, quote_price,
    quote_date, admin_notes).
  - Client: a single narrow allowance — a client may set `client_id` to
    their own `auth.uid()` only on a row where `client_id is null` and
    `email = auth.jwt() ->> 'email'`. No other column may be changed by
    a non-admin. This is the "claim" operation described below.
- **`profiles` table:** a user may select/update only their own row
  (`id = auth.uid()`); admins may select all rows (needed for the admin
  panel, though the admin UI does not need to edit other profiles).

## Submission flow (replaces Formspree)

Wizard step 4 ("Get my free quote") currently POSTs to Formspree. New
behavior:

1. Insert a row into `requests` with the collected fields
   (`email, name, service, urgency, details`), `status = 'submitted'`.
2. Call `supabase.auth.signInWithOtp({ email })` to send a magic-link
   login email for the portal. This call is independent of step 1 —
   its failure does not block the request from being saved.
3. On success of step 1 (the insert), show the existing success screen,
   with copy updated to mention the portal/status link instead of "check
   your inbox for your quote" (e.g., "Check your inbox — you'll get a
   magic link to track your request's status, and your quote within
   24 hours").
4. Remove the Formspree `fetch` call and the Formspree endpoint entirely
   from `index.html`.

## Client portal (`portal.html`)

1. Client enters their email, clicks "Send login link" →
   `supabase.auth.signInWithOtp({ email })`.
2. Client clicks the emailed magic link, lands back on `portal.html`
   authenticated.
3. On authenticated load, portal runs the **claim** step: attempt to
   update any `requests` rows where `email` matches the logged-in
   user's email and `client_id is null`, setting `client_id = auth.uid()`.
   This is a one-time reconciliation so requests submitted before the
   client ever logged in become visible to them. RLS (above) permits
   exactly this update and nothing else.
4. Portal then queries and lists all `requests` visible to this user
   (their own via `client_id` or email match), showing: service,
   submitted date, status (as a friendly label/badge), quote_price and
   quote_date when present. `admin_notes` is never selected/shown here.
5. No editing capability on this page — read-only for the client.

## Admin panel (`admin.html`)

1. Same magic-link login as the portal (same Supabase Auth, same users
   table). If the logged-in user's `profiles.is_admin` is not true, show
   an "access denied" message and stop — do not attempt to load
   request data.
2. If admin, load and list **all** `requests` rows (RLS grants this to
   admins), most recent first.
3. Each row is inline-editable: `status` (dropdown of the five values),
   `quote_price`, `quote_date`, `admin_notes`. Saving does an `update`
   on that row's `id`; RLS's admin-update policy permits this.
4. No creation or deletion of requests from this UI in v1 — only status/
   quote/notes editing.

## Error handling

- **Wizard insert fails:** mirror the existing Formspree-era fix already
  applied — do not show the success screen. Re-enable the submit button,
  show an inline error message, and offer a `mailto:` fallback (as
  currently implemented for the Formspree failure case).
- **Magic-link send fails** (either from the wizard's background call or
  from the portal/admin login form): non-fatal on the wizard (the
  request is already saved regardless); on the portal/admin login form,
  show an inline error and allow retry.
- **Claim-on-login update fails or matches zero rows:** silent no-op —
  this is expected for a client with no prior requests, or is a
  transient issue that self-corrects next login. Do not surface an
  error for this step.
- **Admin update fails:** show an inline error next to the edited row;
  leave the row in its pre-edit state until retried successfully.

## Testing / rollout

No automated test suite is introduced, consistent with the project's
current state (no build step, no existing tests). Manual verification
before considering this done:

1. Submit the wizard anonymously (not logged in) → confirm a row appears
   in `requests` with the right fields and `status = 'submitted'`.
2. Click the resulting magic link → land on the portal → confirm the
   submitted request appears with correct status.
3. Log into the admin panel as the operator account → confirm the same
   request appears in the full list → change its status and set a
   quote_price/quote_date → save.
4. Refresh the client portal → confirm the updated status/quote appear.
5. Attempt to load the admin panel as a non-admin account → confirm
   access is denied and no request data is fetched or shown.
6. Simulate an insert failure (e.g., temporarily wrong Supabase URL/key)
   → confirm the wizard shows the error/fallback path instead of a false
   success screen.

## Migration notes

- Formspree endpoint, its `fetch` call, and any Formspree-specific
  copy/config are removed from `index.html` as part of this work — not
  kept as a fallback.
- Existing leads that already went through Formspree (pre-migration)
  are not backfilled into `requests`; this design only covers requests
  submitted after the change ships.
