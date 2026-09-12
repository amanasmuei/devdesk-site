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
