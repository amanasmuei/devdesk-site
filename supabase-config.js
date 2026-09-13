// Fill these in from your Supabase project: Project Settings > API.
// See supabase/README.md for the full setup steps.
const SUPABASE_URL = 'https://isexjtzemagmghakietv.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_I_TH5ox2QJp56u3cgFe_KQ_gsBjAyHH';

function getSupabaseClient() {
  return supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
}
