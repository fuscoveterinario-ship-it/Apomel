// Projeto Supabase do Bee Guard (instalado dentro do projeto "Rastreia Moura",
// com tudo separado pelo prefixo colmeia_). A chave "anon" é pública por natureza:
// a segurança vem das regras do banco (RLS) e das funções.
export const SUPABASE_URL = "https://vmzmthtsxiwwjtpupclv.supabase.co";
export const SUPABASE_ANON_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZtem10aHRzeGl3d2p0cHVwY2x2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUzNTI3NDIsImV4cCI6MjEwMDkyODc0Mn0.QrM7tjRONWwuFwJ3yIOlPor45-bQGuM4OTxMwVpuNoA";
export const INGEST_URL = `${SUPABASE_URL}/functions/v1/colmeia-ingest`;
