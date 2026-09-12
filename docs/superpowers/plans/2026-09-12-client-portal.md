# Client Portal + Admin Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give clients a login-based status view of their request(s) and give the operator an admin dashboard to manage them, replacing Formspree with direct Supabase writes from the existing wizard.

**Architecture:** Site stays a flat set of static HTML files (no build step). A new Supabase project (Postgres + Auth) is the only backend. Three pages — `index.html` (wizard, modified), `portal.html` (new), `admin.html` (new) — load `@supabase/supabase-js` from a CDN and a shared local `supabase-config.js`, talking to Supabase directly from the browser. Postgres Row Level Security (RLS) plus two `security definer` SQL functions (`is_admin()`, `claim_requests()`) are the entire access-control layer — there is no application server.

**Tech Stack:** Plain HTML/CSS/JS (no framework, no build tool), Supabase (Postgres, Auth, RLS), `@supabase/supabase-js` v2 via CDN.

**Spec:** `docs/superpowers/specs/2026-09-12-client-portal-design.md`

## Global Constraints

- Site remains a flat static HTML site — no build step, no framework, same deploy process as today.
- Formspree (endpoint, fetch call, related copy) is removed entirely from `index.html`, not kept as a fallback.
- Client auth is passwordless (magic link) only — no password fields, no signup form.
- No automated test suite exists or is introduced in this repo. Every task's verification step is a manual, concrete browser/dashboard check with an exact expected result — this replaces unit tests for this project.
- Testing the auth flow requires a real HTTP origin (magic-link redirects don't work over `file://`); serve the site locally with a plain static server (e.g. `python3 -m http.server 8000`) for every manual verification step below.
- `admin_notes` is operator-only and must never be selected/rendered on `portal.html`.
- Status values are exactly: `submitted`, `quoted`, `in_progress`, `delivered`, `declined` — no others.

## Note on deviation from RLS design in the spec

The spec's "claim" access-control section describes a client-side UPDATE policy restricted by column values. Implementing that as literal RLS policies allows a client to piggyback other column changes (e.g. `status`, `quote_price`) onto the one legitimate "claim" update, since Postgres RLS `WITH CHECK` clauses across multiple permissive policies are OR'd together — it does not stop at checking only the touched columns. This plan instead exposes claiming as a `security definer` RPC function (`claim_requests()`) that a client calls; the function itself only ever touches `client_id`, so no other column is ever reachable through it. This fulfills the spec's functional requirement (a client can attach their own past requests to their account by email match, and nothing else) more safely than the literal policy design. Everything else in the spec is implemented as written.

---

### Task 1: Supabase project + database schema

**Files:**
- Create: `supabase/schema.sql`
- Create: `supabase/README.md`

**Interfaces:**
- Produces: tables `public.profiles(id, is_admin, created_at)` and `public.requests(id, client_id, email, name, service, urgency, details, status, quote_price, quote_date, admin_notes, created_at, updated_at)`; RPC functions `public.is_admin() returns boolean` and `public.claim_requests() returns void`, both callable via `supabase.rpc(...)` from the `authenticated` role. Tasks 3-5 consume all of the above.

- [x] **Step 1: Write the schema SQL**

Create `supabase/schema.sql`:

```sql
-- profiles: one row per authenticated user, auto-created on first login.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
-- No policies: profiles is never queried directly from client code.
-- It is only read/written through the security-definer functions below,
-- which bypass RLS as their owning role. The operator sets is_admin
-- by hand in the Supabase table editor (see README.md).

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

grant execute on function public.is_admin() to authenticated;

-- requests: one row per wizard submission.
create table public.requests (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references auth.users(id),
  email text not null,
  name text not null,
  service text not null,
  urgency text not null,
  details text not null,
  status text not null default 'submitted'
    check (status in ('submitted','quoted','in_progress','delivered','declined')),
  quote_price numeric,
  quote_date date,
  admin_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.requests enable row level security;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger requests_set_updated_at
  before update on public.requests
  for each row execute function public.set_updated_at();

-- Anyone (anon or authenticated) can submit a request — this is the public wizard.
create policy "requests_insert_public"
  on public.requests for insert
  with check (true);

-- A row is visible to: its claimed client, its email owner pre-claim, or an admin.
create policy "requests_select_own_or_admin"
  on public.requests for select
  using (
    client_id = auth.uid()
    or email = (auth.jwt() ->> 'email')
    or public.is_admin()
  );

-- Only admins may update requests directly (status, quote, notes, etc).
create policy "requests_update_admin"
  on public.requests for update
  using (public.is_admin())
  with check (public.is_admin());

-- Claiming (attaching unclaimed past requests to the logged-in client) happens
-- only through this function, which touches client_id alone.
create or replace function public.claim_requests()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.requests
  set client_id = auth.uid()
  where client_id is null
    and email = (auth.jwt() ->> 'email');
end;
$$;

grant execute on function public.claim_requests() to authenticated;
```

- [x] **Step 2: Write the setup runbook**

Create `supabase/README.md`:

```markdown
# Supabase setup

One-time setup for the client portal / admin panel backend.

1. Create a project at https://supabase.com (free tier is fine).
2. Open the SQL Editor in the Supabase dashboard, paste in the full
   contents of `schema.sql`, and run it.
3. Go to Project Settings → API. Copy the "Project URL" and the
   "anon public" key into `supabase-config.js` (see that file's
   comments) at the repo root.
4. Go to Authentication → Providers → Email, and confirm "Enable Email
   provider" is on and OTP/magic link sign-in is enabled (this is the
   default).
5. Go to Authentication → URL Configuration and set the Site URL to
   wherever the site is deployed (for local testing, e.g.
   `http://localhost:8000`). Magic links redirect back to this URL.
6. Submit one test request through the wizard (see Task 3+), then in
   the Supabase dashboard go to Authentication → Users, find your own
   user row, copy its `id`. In the SQL Editor run:
   `update public.profiles set is_admin = true where id = '<your-id>';`
   This is the only way to grant admin — there is no UI for it.
```

- [ ] **Step 3: Run the schema and verify in the dashboard**

In the Supabase SQL Editor, run the full contents of `schema.sql`.

Verify: Table Editor shows two new tables, `profiles` and `requests`,
both with RLS enabled (a lock icon next to the table name). Database →
Functions shows `is_admin`, `claim_requests`, `handle_new_user`,
`set_updated_at`.

- [x] **Step 4: Commit**

```bash
git add supabase/schema.sql supabase/README.md
git commit -m "feat: add Supabase schema for client requests + admin access

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: Shared Supabase client config

**Files:**
- Create: `supabase-config.js`

**Interfaces:**
- Consumes: the Supabase Project URL and anon public key from Task 1's dashboard (filled in manually by whoever runs this step, per `supabase/README.md`).
- Produces: global function `getSupabaseClient(): SupabaseClient`, used by `index.html`, `portal.html`, `admin.html` (Tasks 3-5). Requires the global `supabase` object from the CDN script tag to already be loaded on the page before this file is loaded.

- [x] **Step 1: Write the config file**

Create `supabase-config.js`:

```js
// Fill these in from your Supabase project: Project Settings > API.
// See supabase/README.md for the full setup steps.
const SUPABASE_URL = 'https://YOUR-PROJECT-REF.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR-ANON-PUBLIC-KEY';

function getSupabaseClient() {
  return supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
}
```

- [ ] **Step 2: Fill in real project credentials**

Replace `SUPABASE_URL` and `SUPABASE_ANON_KEY` above with the actual
values from the Supabase project created in Task 1 (Project Settings →
API → "Project URL" and "anon public" key). The anon key is meant to be
public/client-side; access is controlled entirely by the RLS policies
from Task 1, not by keeping this key secret.

- [ ] **Step 3: Verify the client initializes**

Create a throwaway `test.html` next to it:

```html
<!DOCTYPE html><html><body>
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="supabase-config.js"></script>
<script>
  const c = getSupabaseClient();
  c.from('requests').select('count').then(r => document.body.textContent = JSON.stringify(r));
</script>
</body></html>
```

Run `python3 -m http.server 8000` in the repo root, open
`http://localhost:8000/test.html`.

Verify: the page renders something like `{"data":[...],"error":null}` —
no thrown JS error in the console, and `error` is `null` (an empty
`requests` table still returns `data`, just an empty/zero result).
Delete `test.html` afterward.

- [x] **Step 4: Commit**

```bash
git add supabase-config.js
git commit -m "feat: add shared Supabase client config

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: Wizard submit → Supabase (remove Formspree)

**Files:**
- Modify: `index.html:420-476` (script block, specifically the `submitAll` function and its Formspree call)

**Interfaces:**
- Consumes: `getSupabaseClient()` from Task 2.
- Produces: a row in `public.requests` per wizard submission, and a magic-link sign-in attempt for the submitting email — consumed by Task 4 (portal) and Task 5 (admin) for end-to-end verification.

- [x] **Step 1: Add the CDN and config script tags**

In `index.html`, immediately before the existing closing `<script>` block
(the one starting with `/* nav solidify on scroll */`), add:

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="supabase-config.js"></script>
```

- [x] **Step 2: Replace `submitAll()`**

Replace the existing `submitAll` function (the one that builds a
`URLSearchParams` body and `fetch`es `formspree.io`) with:

```js
async function submitAll(){
  state.name=document.getElementById('w-name').value.trim();
  state.email=document.getElementById('w-email').value.trim();
  const err=document.getElementById('err2');
  if(!state.name){err.textContent='Please tell us your name.';return;}
  if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(state.email)){err.textContent="That email doesn't look right.";return;}
  err.textContent='';
  const btn=document.getElementById('submitBtn');
  btn.disabled=true;btn.textContent='Sending…';
  const client=getSupabaseClient();
  const {error}=await client.from('requests').insert({
    name:state.name,email:state.email,service:state.service,
    urgency:state.urgency,details:state.details
  });
  if(error){
    console.warn('supabase insert error',error);
    btn.disabled=false;btn.textContent='Get my free quote';
    err.textContent='Something went wrong sending your request. Please try again, or email us directly at amanasmuei@gmail.com.';
    return;
  }
  client.auth.signInWithOtp({email:state.email}).catch(e=>console.warn('magic link send failed',e));
  document.querySelector('.wizard-shell').innerHTML=`
    <div class="success" style="display:block">
      <div class="ring">✓</div>
      <h3>Request sent, ${state.name.split(' ')[0]}</h3>
      <p>Check <b style="color:var(--text)">${state.email}</b> for a login link to track your request's status, and your fixed quote within 24 hours.</p>
    </div>`;
}
```

This removes the Formspree `fetch` call, the `_subject`/`Timeline`/`Details`
`URLSearchParams` body, and the try/catch-then-succeed-anyway pattern —
insert failure now blocks the success screen (matching the error-handling
already fixed in a prior change), and the magic-link send is fire-and-forget
since a failed send should never block a saved request.

- [ ] **Step 3: Manually verify the submission**

Run `python3 -m http.server 8000`, open `http://localhost:8000/index.html`,
scroll to the wizard, complete all four steps with a real email you can
check, and submit.

Verify: the success screen appears with the updated copy. In the Supabase
dashboard, Table Editor → `requests` shows a new row with the fields you
entered and `status = submitted`. Authentication → Users shows a new (or
existing) user for that email. Your inbox receives a magic-link sign-in
email from Supabase.

- [ ] **Step 4: Verify the failure path still works**

Temporarily change `SUPABASE_URL` in `supabase-config.js` to an invalid
value (e.g. append `x` to it), reload, and submit the wizard again.

Verify: the button re-enables, the error message appears
("Something went wrong sending your request...") and the success screen
does NOT appear. Revert `supabase-config.js` back to the correct URL
afterward.

- [x] **Step 5: Commit**

```bash
git add index.html
git commit -m "feat: replace Formspree with direct Supabase insert in wizard

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: Client portal page

**Files:**
- Create: `portal.html`

**Interfaces:**
- Consumes: `getSupabaseClient()` from Task 2; the `requests` table and `claim_requests()` RPC from Task 1; requires at least one submitted request (Task 3) to verify against.
- Produces: nothing consumed by later tasks — this is a leaf page.

- [x] **Step 1: Write the portal page**

Create `portal.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>DevDesk — Your requests</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<style>
  :root{
    --bg:#0a0c11; --surface:#10131b; --border:rgba(255,255,255,.07);
    --text:#f4f6fb; --muted:#98a2b8; --faint:#667085;
    --accent:#7c8cff; --radius:14px;
  }
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:'Inter',-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
    background:var(--bg);color:var(--text);line-height:1.6;-webkit-font-smoothing:antialiased}
  .wrap{max-width:640px;margin:0 auto;padding:60px 24px}
  h1{font-size:1.8rem;font-weight:800;letter-spacing:-.03em;margin-bottom:8px}
  .sub{color:var(--muted);margin-bottom:32px}
  input[type=email]{width:100%;background:var(--surface);border:1px solid var(--border);
    color:var(--text);border-radius:12px;padding:15px 16px;font-size:16px;font-family:inherit;outline:none}
  input:focus{border-color:var(--accent)}
  .btn{margin-top:12px;display:inline-block;padding:13px 24px;border-radius:11px;font-weight:700;
    background:#fff;color:#0a0c11;border:none;cursor:pointer;font-size:.93rem;font-family:inherit}
  .btn:disabled{opacity:.5;cursor:not-allowed}
  .msg{margin-top:14px;font-size:.88rem;color:var(--muted)}
  .msg.error{color:#f97066}
  .card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);
    padding:20px 22px;margin-bottom:12px}
  .card .row{display:flex;justify-content:space-between;gap:12px;align-items:baseline;flex-wrap:wrap}
  .card h3{font-size:1.02rem;font-weight:700}
  .badge{font-size:.76rem;font-weight:600;padding:4px 10px;border-radius:999px;
    background:rgba(124,140,255,.12);color:var(--accent);text-transform:capitalize}
  .card .meta{color:var(--faint);font-size:.85rem;margin-top:6px}
  .card .quote{margin-top:10px;font-size:.92rem;color:var(--text)}
  [hidden]{display:none!important}
</style>
</head>
<body>
<div class="wrap">
  <h1>Your requests</h1>
  <p class="sub">Log in with the email you used to submit a request.</p>

  <div id="loginBox">
    <input type="email" id="loginEmail" placeholder="you@example.com">
    <button class="btn" id="loginBtn">Send login link</button>
    <p class="msg" id="loginMsg"></p>
  </div>

  <div id="listBox" hidden>
    <p class="sub" id="whoami"></p>
    <div id="requests"></div>
  </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="supabase-config.js"></script>
<script>
const client=getSupabaseClient();
const loginBox=document.getElementById('loginBox');
const listBox=document.getElementById('listBox');
const loginMsg=document.getElementById('loginMsg');
const loginBtn=document.getElementById('loginBtn');

loginBtn.addEventListener('click',async()=>{
  const email=document.getElementById('loginEmail').value.trim();
  if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)){
    loginMsg.classList.add('error');loginMsg.textContent="That email doesn't look right.";return;
  }
  loginBtn.disabled=true;loginMsg.classList.remove('error');loginMsg.textContent='Sending…';
  const{error}=await client.auth.signInWithOtp({email});
  loginBtn.disabled=false;
  if(error){loginMsg.classList.add('error');loginMsg.textContent='Could not send link. Please try again.';return;}
  loginMsg.textContent='Check your inbox for a login link.';
});

function statusLabel(s){
  return({submitted:'Submitted',quoted:'Quoted',in_progress:'In progress',
    delivered:'Delivered',declined:'Declined'})[s]||s;
}

function renderRequests(rows){
  const el=document.getElementById('requests');
  if(rows.length===0){el.innerHTML='<p class="sub">No requests yet.</p>';return;}
  el.innerHTML=rows.map(r=>`
    <div class="card">
      <div class="row"><h3>${r.service}</h3><span class="badge">${statusLabel(r.status)}</span></div>
      <div class="meta">Submitted ${new Date(r.created_at).toLocaleDateString()}</div>
      ${r.quote_price!=null?`<div class="quote">Quote: RM${r.quote_price}${r.quote_date?' · by '+new Date(r.quote_date).toLocaleDateString():''}</div>`:''}
    </div>`).join('');
}

async function loadPortal(user){
  loginBox.hidden=true;listBox.hidden=false;
  document.getElementById('whoami').textContent=`Logged in as ${user.email}`;
  await client.rpc('claim_requests');
  const{data,error}=await client.from('requests')
    .select('id, service, status, quote_price, quote_date, created_at')
    .order('created_at',{ascending:false});
  if(error){document.getElementById('requests').innerHTML='<p class="msg error">Could not load your requests. Refresh to try again.</p>';return;}
  renderRequests(data);
}

client.auth.onAuthStateChange((_e,session)=>{if(session&&session.user)loadPortal(session.user);});
client.auth.getSession().then(({data})=>{if(data.session&&data.session.user)loadPortal(data.session.user);});
</script>
</body>
</html>
```

- [ ] **Step 2: Manually verify**

With `python3 -m http.server 8000` running, open
`http://localhost:8000/portal.html`, enter the same email used in Task 3's
test submission, click "Send login link", then open that email and click
the link.

Verify: you land back on `portal.html` logged in, "No requests yet" does
NOT show — the request from Task 3 appears with the correct service name
and a "Submitted" badge. `admin_notes` is never shown anywhere on this
page (it isn't in the select list above, by design).

- [x] **Step 3: Commit**

```bash
git add portal.html
git commit -m "feat: add client portal for tracking request status

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: Admin panel page

**Files:**
- Create: `admin.html`

**Interfaces:**
- Consumes: `getSupabaseClient()` from Task 2; `is_admin()` RPC and the `requests` table (admin update policy) from Task 1.
- Produces: nothing consumed by later tasks — this is a leaf page.

- [x] **Step 1: Write the admin page**

Create `admin.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>DevDesk — Admin</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<style>
  :root{
    --bg:#0a0c11; --surface:#10131b; --border:rgba(255,255,255,.07);
    --text:#f4f6fb; --muted:#98a2b8; --faint:#667085; --radius:14px;
  }
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:'Inter',-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
    background:var(--bg);color:var(--text);line-height:1.6;-webkit-font-smoothing:antialiased}
  .wrap{max-width:1100px;margin:0 auto;padding:48px 24px}
  h1{font-size:1.6rem;font-weight:800;letter-spacing:-.03em;margin-bottom:20px}
  input[type=email]{width:100%;max-width:360px;background:var(--surface);border:1px solid var(--border);
    color:var(--text);border-radius:12px;padding:14px 16px;font-size:16px;font-family:inherit;outline:none}
  .btn{margin-top:12px;display:inline-block;padding:12px 22px;border-radius:11px;font-weight:700;
    background:#fff;color:#0a0c11;border:none;cursor:pointer;font-size:.9rem;font-family:inherit}
  .btn:disabled{opacity:.5;cursor:not-allowed}
  .msg{margin-top:14px;font-size:.88rem;color:var(--muted)}
  .msg.error{color:#f97066}
  table{width:100%;border-collapse:collapse;font-size:.88rem}
  th,td{border-bottom:1px solid var(--border);padding:10px 8px;text-align:left;vertical-align:top}
  th{color:var(--faint);font-weight:600;text-transform:uppercase;font-size:.72rem;letter-spacing:.06em}
  select,input[type=number],input[type=date],textarea.notes{
    background:var(--surface);border:1px solid var(--border);color:var(--text);
    border-radius:8px;padding:6px 8px;font-size:.85rem;font-family:inherit;width:100%}
  textarea.notes{min-height:44px;resize:vertical}
  .rowmsg{font-size:.78rem;color:var(--faint);margin-top:4px}
  .rowmsg.error{color:#f97066}
  .savebtn{padding:6px 12px;border-radius:8px;border:1px solid var(--border);background:transparent;
    color:var(--text);cursor:pointer;font-size:.8rem;font-family:inherit}
  [hidden]{display:none!important}
</style>
</head>
<body>
<div class="wrap">
  <h1>DevDesk admin</h1>

  <div id="loginBox">
    <input type="email" id="loginEmail" placeholder="you@example.com">
    <br><button class="btn" id="loginBtn">Send login link</button>
    <p class="msg" id="loginMsg"></p>
  </div>

  <p class="msg error" id="deniedMsg" hidden>Not authorized for this page.</p>

  <div id="tableBox" hidden>
    <table>
      <thead>
        <tr>
          <th>Submitted</th><th>Client</th><th>Service</th><th>Details</th>
          <th>Urgency</th><th>Status</th><th>Quote (RM)</th><th>Quote date</th>
          <th>Notes</th><th></th>
        </tr>
      </thead>
      <tbody id="rows"></tbody>
    </table>
  </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="supabase-config.js"></script>
<script>
const client=getSupabaseClient();
const STATUSES=['submitted','quoted','in_progress','delivered','declined'];

const loginBox=document.getElementById('loginBox');
const deniedMsg=document.getElementById('deniedMsg');
const tableBox=document.getElementById('tableBox');
const loginMsg=document.getElementById('loginMsg');
const loginBtn=document.getElementById('loginBtn');

loginBtn.addEventListener('click',async()=>{
  const email=document.getElementById('loginEmail').value.trim();
  if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)){
    loginMsg.classList.add('error');loginMsg.textContent="That email doesn't look right.";return;
  }
  loginBtn.disabled=true;loginMsg.classList.remove('error');loginMsg.textContent='Sending…';
  const{error}=await client.auth.signInWithOtp({email});
  loginBtn.disabled=false;
  if(error){loginMsg.classList.add('error');loginMsg.textContent='Could not send link. Please try again.';return;}
  loginMsg.textContent='Check your inbox for a login link.';
});

function rowHtml(r){
  return `
    <tr data-id="${r.id}">
      <td>${new Date(r.created_at).toLocaleDateString()}</td>
      <td>${r.name}<br><span style="color:var(--faint)">${r.email}</span></td>
      <td>${r.service}</td>
      <td style="max-width:260px">${r.details}</td>
      <td>${r.urgency}</td>
      <td><select class="f-status">${STATUSES.map(s=>`<option value="${s}" ${s===r.status?'selected':''}>${s}</option>`).join('')}</select></td>
      <td><input class="f-price" type="number" step="0.01" value="${r.quote_price??''}"></td>
      <td><input class="f-date" type="date" value="${r.quote_date??''}"></td>
      <td><textarea class="f-notes notes">${r.admin_notes??''}</textarea></td>
      <td><button class="savebtn">Save</button><p class="rowmsg"></p></td>
    </tr>`;
}

function wireRow(tr,id){
  tr.querySelector('.savebtn').addEventListener('click',async()=>{
    const rowmsg=tr.querySelector('.rowmsg');
    const patch={
      status:tr.querySelector('.f-status').value,
      quote_price:tr.querySelector('.f-price').value===''?null:Number(tr.querySelector('.f-price').value),
      quote_date:tr.querySelector('.f-date').value||null,
      admin_notes:tr.querySelector('.f-notes').value||null,
    };
    rowmsg.classList.remove('error');rowmsg.textContent='Saving…';
    const{error}=await client.from('requests').update(patch).eq('id',id);
    if(error){rowmsg.classList.add('error');rowmsg.textContent='Save failed. Try again.';return;}
    rowmsg.textContent='Saved.';
  });
}

async function loadAdmin(){
  const{data,error}=await client.from('requests')
    .select('id, name, email, service, urgency, details, status, quote_price, quote_date, admin_notes, created_at')
    .order('created_at',{ascending:false});
  if(error){tableBox.hidden=true;deniedMsg.hidden=false;return;}
  const tbody=document.getElementById('rows');
  tbody.innerHTML=data.map(rowHtml).join('');
  data.forEach(r=>wireRow(tbody.querySelector(`tr[data-id="${r.id}"]`),r.id));
  tableBox.hidden=false;
}

async function handleSession(){
  loginBox.hidden=true;
  const{data:isAdmin,error}=await client.rpc('is_admin');
  if(error||!isAdmin){deniedMsg.hidden=false;return;}
  await loadAdmin();
}

client.auth.onAuthStateChange((_e,session)=>{if(session&&session.user)handleSession();});
client.auth.getSession().then(({data})=>{if(data.session&&data.session.user)handleSession();});
</script>
</body>
</html>
```

- [ ] **Step 2: Grant yourself admin**

Follow `supabase/README.md` step 6: find your own user id in Authentication
→ Users, then in the SQL Editor run:

```sql
update public.profiles set is_admin = true where id = '<your-user-id>';
```

(Your `profiles` row exists already if you've ever logged in via magic
link on `portal.html` or `admin.html` — the `on_auth_user_created` trigger
from Task 1 creates it.)

- [ ] **Step 3: Manually verify admin access and editing**

With the local server running, open `http://localhost:8000/admin.html`,
log in with the email you just granted `is_admin` to.

Verify: the table appears (not "Not authorized") listing the request from
Task 3. Change its status to `quoted`, set a quote price and date, add a
note, click Save — "Saved." appears next to that row.

- [ ] **Step 4: Verify a non-admin is denied**

Log in to `admin.html` with a different email (one without `is_admin`
set).

Verify: "Not authorized for this page." shows and no table/data appears.

- [ ] **Step 5: Verify the update reaches the client portal**

Reopen `http://localhost:8000/portal.html` (already logged in from Task
4, or log in again).

Verify: the request now shows the `Quoted` badge and the quote price/date
you set in Step 3 — `admin_notes` still does not appear anywhere on this
page.

- [x] **Step 6: Commit**

```bash
git add admin.html
git commit -m "feat: add admin panel for managing request status and quotes

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 6: Final cleanup and end-to-end pass

**Files:**
- Modify: `index.html` (verify no Formspree references remain)
- Modify: `docs/superpowers/specs/2026-09-12-client-portal-design.md` (status line)

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: nothing — terminal task.

- [x] **Step 1: Confirm Formspree is fully gone**

```bash
grep -ri formspree index.html
```

Expected: no output. If anything matches, remove it — Task 3 should have
already deleted it, so this is a safety check, not new work.

- [ ] **Step 2: Run the full spec rollout checklist**

With the local server running, work through every numbered item in the
spec's "Testing / rollout" section
(`docs/superpowers/specs/2026-09-12-client-portal-design.md`) in order,
using a fresh email you haven't used yet for a clean anonymous-submission
test. All six items should already be covered by Tasks 3-5's individual
verifications; this step is doing them back-to-back in one uninterrupted
pass to catch any interaction between steps.

Verify: all six items pass as described in the spec.

- [ ] **Step 3: Update the spec status**

In `docs/superpowers/specs/2026-09-12-client-portal-design.md`, change:

```
**Status:** Approved, pending implementation plan
```

to:

```
**Status:** Implemented
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-09-12-client-portal-design.md
git commit -m "docs: mark client portal design as implemented

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```
