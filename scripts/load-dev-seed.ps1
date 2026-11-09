# Carrega os DADOS FICTÍCIOS DE TESTE no banco LOCAL (contêiner do supabase start).
# Nunca use contra staging/produção: este script só fala com o contêiner local.
# Compatível com Windows PowerShell 5.1. Sem 'Stop' na chamada nativa: o psql escreve NOTICE no stderr.
$container = 'supabase_db_myfluenti-backend'
$root = Split-Path -Parent $PSScriptRoot
$sqlFile = Join-Path $root 'supabase\dev-seed\dev_content.sql'

$running = @(docker ps --format '{{.Names}}')
if ($running -notcontains $container) {
  Write-Host "ERRO: contêiner '$container' não está rodando. Rode 'supabase start' (banco local) primeiro." -ForegroundColor Red
  exit 1
}

$code = 1
Push-Location $root
try {
  docker cp $sqlFile "${container}:/tmp/dev_content.sql"
  if ($LASTEXITCODE -ne 0) { $code = $LASTEXITCODE }
  else {
    # O psql roda dentro do contêiner (UTF-8 preservado); 2>&1 fica dentro do sh -c.
    docker exec $container sh -c 'psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/dev_content.sql 2>&1; rc=$?; rm -f /tmp/dev_content.sql; exit $rc'
    $code = $LASTEXITCODE
  }
} finally {
  Pop-Location
}
exit $code
