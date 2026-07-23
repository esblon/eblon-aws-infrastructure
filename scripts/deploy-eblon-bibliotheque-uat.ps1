# EBLON Bibliotheque - deploiement UAT AWS NonProd
# Images applicatives immuables : commit a948138
# Execution : PowerShell depuis n'importe quel repertoire du poste local.

[CmdletBinding()]
param(
  [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
  [string] $EmailFrom = "onboarding@resend.dev",

  [switch] $EnablePublicSignup
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProgressPreference = "SilentlyContinue"

$region            = "eu-west-3"
$profile           = "blon-nonprod"
$dnsProfile        = "blon-sharedservices"
$stackName         = "blon-nonprod-core"
$expectedAccountId = "273956034614"
$expectedDnsAccountId = "268140507002"
$repositoryName    = "blon/eblon-bibliotheque"
$runtimeTag        = "a948138-runtime-amd64"
$migrationTag      = "a948138-migration-amd64"
$publicSignupValue = if ($EnablePublicSignup) { "true" } else { "false" }
$domain            = "blon-enterprises.com"
$fqdn              = "uat.biblio.blon-enterprises.com"
$runtimeParameterName = "/blon/nonprod/bibliotheque/runtime/app-env"
$resendApiKeyParameterName = "/blon/uat/eblon-bibliotheque/resend-api-key"

function ConvertFrom-AwsJson {
  param(
    [Parameter(Mandatory = $true)]
    [string[]] $AwsArguments,

    [Parameter(Mandatory = $true)]
    [string] $FailureMessage
  )

  $output = @(& aws @AwsArguments)
  $exitCode = $LASTEXITCODE

  if ($exitCode -ne 0) {
    throw $FailureMessage
  }

  return (($output -join "`n") | ConvertFrom-Json)
}

function Set-DotEnvValue {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Content,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Z][A-Z0-9_]*$')]
    [string] $Name,

    [Parameter(Mandatory = $true)]
    [string] $Value
  )

  if ($Value -match "[`r`n]") {
    throw "La valeur de $Name contient un retour a la ligne interdit"
  }

  $normalizedContent = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
  $lines = [regex]::Split($normalizedContent, "`n")
  $result = [System.Collections.Generic.List[string]]::new()
  $pattern = "^$([regex]::Escape($Name))="
  $written = $false

  foreach ($line in $lines) {
    if ($line -match $pattern) {
      if (-not $written) {
        [void] $result.Add("${Name}=${Value}")
        $written = $true
      }

      continue
    }

    [void] $result.Add($line)
  }

  if (-not $written) {
    [void] $result.Add("${Name}=${Value}")
  }

  return (($result -join "`n").TrimEnd([char[]] ("`n")) + "`n")
}

function Update-BibliothequeRuntimeParameter {
  param(
    [Parameter(Mandatory = $true)]
    [string] $RuntimeParameterName,

    [Parameter(Mandatory = $true)]
    [string] $ResendApiKeyParameterName,

    [Parameter(Mandatory = $true)]
    [string] $EmailFrom,

    [Parameter(Mandatory = $true)]
    [ValidateSet("true", "false")]
    [string] $PublicSignupEnabled,

    [Parameter(Mandatory = $true)]
    [string] $Region,

    [Parameter(Mandatory = $true)]
    [string] $Profile
  )

  $runtimeParameter = ConvertFrom-AwsJson `
    -AwsArguments @(
      "ssm", "get-parameter",
      "--name", $RuntimeParameterName,
      "--with-decryption",
      "--region", $Region,
      "--profile", $Profile,
      "--output", "json",
      "--no-cli-pager"
    ) `
    -FailureMessage "Lecture du SecureString runtime impossible : $RuntimeParameterName"

  $resendParameter = ConvertFrom-AwsJson `
    -AwsArguments @(
      "ssm", "get-parameter",
      "--name", $ResendApiKeyParameterName,
      "--with-decryption",
      "--region", $Region,
      "--profile", $Profile,
      "--output", "json",
      "--no-cli-pager"
    ) `
    -FailureMessage "Lecture du SecureString Resend impossible : $ResendApiKeyParameterName"

  if ($runtimeParameter.Parameter.Type -ne "SecureString") {
    throw "Le parametre runtime n'est pas un SecureString"
  }

  if ($resendParameter.Parameter.Type -ne "SecureString") {
    throw "Le parametre Resend n'est pas un SecureString"
  }

  $runtimeValue = [string] $runtimeParameter.Parameter.Value
  $resendApiKey = [string] $resendParameter.Parameter.Value

  if ([string]::IsNullOrWhiteSpace($runtimeValue)) {
    throw "Le SecureString runtime est vide"
  }

  if ($resendApiKey -notmatch '^re_[^\s]+$') {
    throw "La valeur du SecureString Resend n'a pas le format attendu"
  }

  $updatedRuntimeValue = Set-DotEnvValue `
    -Content $runtimeValue `
    -Name "EMAIL_ENABLED" `
    -Value "true"
  $updatedRuntimeValue = Set-DotEnvValue `
    -Content $updatedRuntimeValue `
    -Name "EMAIL_FROM" `
    -Value $EmailFrom
  $updatedRuntimeValue = Set-DotEnvValue `
    -Content $updatedRuntimeValue `
    -Name "RESEND_API_KEY" `
    -Value $resendApiKey
  $updatedRuntimeValue = Set-DotEnvValue `
    -Content $updatedRuntimeValue `
    -Name "PUBLIC_SIGNUP_ENABLED" `
    -Value $PublicSignupEnabled

  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  $runtimeSizeBytes = $utf8NoBom.GetByteCount($updatedRuntimeValue)

  if ($runtimeSizeBytes -gt 4096) {
    throw "La configuration runtime depasse la limite de 4 Kio d'un parametre Standard"
  }

  if ($updatedRuntimeValue -ceq $runtimeValue) {
    Write-Host "[OK] Configuration e-mail runtime deja a jour" -ForegroundColor Green
    return
  }

  $valueFileName = "blon-runtime-$([guid]::NewGuid().ToString('N')).env"
  $valueFilePath = Join-Path $env:TEMP $valueFileName

  try {
    [System.IO.File]::WriteAllText(
      $valueFilePath,
      $updatedRuntimeValue,
      $utf8NoBom
    )

    Push-Location $env:TEMP

    try {
      $putOutput = @(
        aws ssm put-parameter `
          --name $RuntimeParameterName `
          --value "file://$valueFileName" `
          --overwrite `
          --region $Region `
          --profile $Profile `
          --output json `
          --no-cli-pager
      )
      $putExitCode = $LASTEXITCODE
    } finally {
      Pop-Location
    }

    if ($putExitCode -ne 0) {
      throw "Mise a jour du SecureString runtime impossible"
    }

    $putResult = (($putOutput -join "`n") | ConvertFrom-Json)
    Write-Host "[OK] Configuration e-mail runtime activee, version $($putResult.Version)" -ForegroundColor Green
  } finally {
    Remove-Item -LiteralPath $valueFilePath -Force -ErrorAction SilentlyContinue
    $runtimeValue = $null
    $updatedRuntimeValue = $null
    $resendApiKey = $null
  }
}

$identityOutput = @(
  aws sts get-caller-identity `
    --profile $profile `
    --output json 2>$null
)
$identityExitCode = $LASTEXITCODE

if ($identityExitCode -ne 0) {
  aws sso login --profile $profile

  if ($LASTEXITCODE -ne 0) {
    throw "Connexion AWS SSO impossible"
  }

  $identityOutput = @(
    aws sts get-caller-identity `
      --profile $profile `
      --output json
  )

  if ($LASTEXITCODE -ne 0) {
    throw "Identite AWS impossible a verifier"
  }
}

$identity = (($identityOutput -join "`n") | ConvertFrom-Json)

if ($identity.Account -ne $expectedAccountId) {
  throw "Mauvais compte AWS : $($identity.Account) au lieu de $expectedAccountId"
}

$dnsIdentityOutput = @(
  aws sts get-caller-identity `
    --profile $dnsProfile `
    --output json 2>$null
)
$dnsIdentityExitCode = $LASTEXITCODE

if ($dnsIdentityExitCode -ne 0) {
  aws sso login --profile $dnsProfile

  if ($LASTEXITCODE -ne 0) {
    throw "Connexion AWS SSO SharedServices impossible"
  }

  $dnsIdentityOutput = @(
    aws sts get-caller-identity `
      --profile $dnsProfile `
      --output json
  )

  if ($LASTEXITCODE -ne 0) {
    throw "Identite AWS SharedServices impossible a verifier"
  }
}

$dnsIdentity = (($dnsIdentityOutput -join "`n") | ConvertFrom-Json)

if ($dnsIdentity.Account -ne $expectedDnsAccountId) {
  throw "Mauvais compte DNS AWS : $($dnsIdentity.Account) au lieu de $expectedDnsAccountId"
}

Update-BibliothequeRuntimeParameter `
  -RuntimeParameterName $runtimeParameterName `
  -ResendApiKeyParameterName $resendApiKeyParameterName `
  -EmailFrom $EmailFrom `
  -PublicSignupEnabled $publicSignupValue `
  -Region $region `
  -Profile $profile

$stack = ConvertFrom-AwsJson `
  -AwsArguments @(
    "cloudformation", "describe-stacks",
    "--stack-name", $stackName,
    "--region", $region,
    "--profile", $profile,
    "--output", "json"
  ) `
  -FailureMessage "Lecture de la stack $stackName impossible"

$outputs = @($stack.Stacks[0].Outputs)

function Get-StackOutput {
  param([Parameter(Mandatory = $true)][string] $Key)

  $value = $outputs |
    Where-Object { $_.OutputKey -eq $Key } |
    Select-Object -ExpandProperty OutputValue -First 1

  if (-not $value) {
    throw "Output CloudFormation introuvable : $Key"
  }

  return [string] $value
}

$instanceId     = Get-StackOutput -Key "InstanceId"
$elasticIp      = Get-StackOutput -Key "ElasticIPAddress"
$repositoryUri  = Get-StackOutput -Key "BibliothequeRepositoryUri"
$registry       = $repositoryUri.Split("/")[0]
$runtimeImage   = "${repositoryUri}:${runtimeTag}"
$migrationImage = "${repositoryUri}:${migrationTag}"

$expectedRepositoryUri = "${expectedAccountId}.dkr.ecr.${region}.amazonaws.com/${repositoryName}"

if ($repositoryUri -ne $expectedRepositoryUri) {
  throw "Depot ECR inattendu : $repositoryUri"
}

foreach ($tag in @($runtimeTag, $migrationTag)) {
  $imageDetails = ConvertFrom-AwsJson `
    -AwsArguments @(
      "ecr", "describe-images",
      "--repository-name", $repositoryName,
      "--image-ids", "imageTag=$tag",
      "--region", $region,
      "--profile", $profile,
      "--output", "json",
      "--no-cli-pager"
    ) `
    -FailureMessage "Image ECR introuvable : $tag"

  $imageDetail = @($imageDetails.imageDetails)[0]

  $allowedManifestTypes = @(
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json"
  )

  if ($imageDetail.imageManifestMediaType -notin $allowedManifestTypes) {
    throw "Type de manifeste incorrect pour $tag : $($imageDetail.imageManifestMediaType)"
  }

  $scan = ConvertFrom-AwsJson `
    -AwsArguments @(
      "ecr", "describe-image-scan-findings",
      "--repository-name", $repositoryName,
      "--image-id", "imageTag=$tag",
      "--query", "{Status:imageScanStatus.status,Counts:imageScanFindings.findingSeverityCounts}",
      "--region", $region,
      "--profile", $profile,
      "--output", "json",
      "--no-cli-pager"
    ) `
    -FailureMessage "Resultat du scan ECR illisible : $tag"

  if ($scan.Status -ne "COMPLETE") {
    throw "Scan ECR non termine pour $tag : $($scan.Status)"
  }

  $criticalProperty = $scan.Counts.PSObject.Properties["CRITICAL"]
  $criticalCount = if ($null -eq $criticalProperty) {
    0
  } else {
    [int] $criticalProperty.Value
  }

  if ($criticalCount -ne 0) {
    throw "Image interdite : $tag contient $criticalCount CRITICAL"
  }

  Write-Host "[OK] Image ECR autorisee : $tag" -ForegroundColor Green
}

$zones = ConvertFrom-AwsJson `
  -AwsArguments @(
    "route53", "list-hosted-zones-by-name",
    "--dns-name", "${domain}.",
    "--profile", $dnsProfile,
    "--output", "json",
    "--no-cli-pager"
  ) `
  -FailureMessage "Lecture des zones Route 53 impossible"

$publicZones = @(
  $zones.HostedZones |
    Where-Object {
      $_.Name -eq "${domain}." -and
      $_.Config.PrivateZone -eq $false
    }
)

if ($publicZones.Count -ne 1) {
  throw "Une zone publique Route 53 exacte est attendue pour ${domain}; trouvee(s) : $($publicZones.Count)"
}

$hostedZone = $publicZones[0]
$hostedZoneId = ([string] $hostedZone.Id) -replace '^/hostedzone/', ''

$recordSets = ConvertFrom-AwsJson `
  -AwsArguments @(
    "route53", "list-resource-record-sets",
    "--hosted-zone-id", $hostedZoneId,
    "--start-record-name", "${fqdn}.",
    "--max-items", "10",
    "--profile", $dnsProfile,
    "--output", "json",
    "--no-cli-pager"
  ) `
  -FailureMessage "Lecture des enregistrements Route 53 impossible"

$sameNameRecords = @(
  $recordSets.ResourceRecordSets |
    Where-Object { $_.Name -eq "${fqdn}." }
)

$cnameRecord = @(
  $sameNameRecords |
    Where-Object { $_.Type -eq "CNAME" }
)

if ($cnameRecord.Count -gt 0) {
  throw "Un CNAME existe deja pour $fqdn; aucune modification automatique n'a ete faite"
}

$aRecords = @(
  $sameNameRecords |
    Where-Object { $_.Type -eq "A" }
)

if ($aRecords.Count -gt 1) {
  throw "Plusieurs jeux d'enregistrements A inattendus existent pour $fqdn"
}

$dnsChangeRequired = $true

if ($aRecords.Count -eq 1) {
  $aRecord = $aRecords[0]
  $aliasProperty = $aRecord.PSObject.Properties["AliasTarget"]

  if ($null -ne $aliasProperty) {
    throw "Un Alias A existe deja pour $fqdn; aucune modification automatique n'a ete faite"
  }

  $resourceRecordsProperty = $aRecord.PSObject.Properties["ResourceRecords"]

  if ($null -eq $resourceRecordsProperty) {
    throw "L'enregistrement A de $fqdn ne contient aucune valeur exploitable"
  }

  $currentValues = @(
    $resourceRecordsProperty.Value |
      ForEach-Object { [string] $_.Value }
  )

  if ($currentValues.Count -eq 1 -and $currentValues[0] -eq $elasticIp) {
    $dnsChangeRequired = $false
    Write-Host "[OK] Route 53 deja configure : $fqdn -> $elasticIp" -ForegroundColor Green
  } else {
    throw "L'enregistrement A existant de $fqdn ne pointe pas exclusivement vers $elasticIp"
  }
}

if ($dnsChangeRequired) {
  $changeBatch = @{
    Comment = "EBLON Bibliotheque UAT vers Elastic IP BLON NonProd"
    Changes = @(
      @{
        Action = "UPSERT"
        ResourceRecordSet = @{
          Name = "${fqdn}."
          Type = "A"
          TTL = 60
          ResourceRecords = @(
            @{ Value = $elasticIp }
          )
        }
      }
    )
  }

  $changeFileName = "blon-route53-$([guid]::NewGuid().ToString('N')).json"
  $changeFilePath = Join-Path $env:TEMP $changeFileName

  try {
    [System.IO.File]::WriteAllText(
      $changeFilePath,
      ($changeBatch | ConvertTo-Json -Depth 10),
      [System.Text.UTF8Encoding]::new($false)
    )

    Push-Location $env:TEMP

    try {
      $changeOutput = @(
        aws route53 change-resource-record-sets `
          --hosted-zone-id $hostedZoneId `
          --change-batch "file://$changeFileName" `
          --profile $dnsProfile `
          --output json `
          --no-cli-pager
      )
      $changeExitCode = $LASTEXITCODE
    } finally {
      Pop-Location
    }

    if ($changeExitCode -ne 0) {
      throw "Creation de l'enregistrement Route 53 impossible"
    }

    $change = (($changeOutput -join "`n") | ConvertFrom-Json)
    $changeId = [string] $change.ChangeInfo.Id

    aws route53 wait resource-record-sets-changed `
      --id $changeId `
      --profile $dnsProfile

    if ($LASTEXITCODE -ne 0) {
      throw "Le changement Route 53 n'a pas atteint INSYNC"
    }

    Write-Host "[OK] Route 53 configure : $fqdn -> $elasticIp" -ForegroundColor Green
  } finally {
    Remove-Item -LiteralPath $changeFilePath -Force -ErrorAction SilentlyContinue
  }
}

$composeContent = @'
name: eblon-bibliotheque-uat

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  postgres:
    image: postgres:17.6-alpine3.22
    environment:
      POSTGRES_DB: ${POSTGRES_DB:?POSTGRES_DB must be supplied at compose runtime}
      POSTGRES_USER: ${POSTGRES_USER:?POSTGRES_USER must be supplied at compose runtime}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be supplied at compose runtime}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks: [backend]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s
    restart: unless-stopped
    mem_limit: 700m
    cpus: 0.75
    logging: *default-logging

  migrate:
    image: __MIGRATION_IMAGE__
    env_file:
      - /opt/blon/bibliotheque/runtime/app.env
    depends_on:
      postgres:
        condition: service_healthy
    networks: [backend]
    restart: "no"
    mem_limit: 350m
    cpus: 0.5
    logging: *default-logging

  app:
    image: __RUNTIME_IMAGE__
    env_file:
      - /opt/blon/bibliotheque/runtime/app.env
    expose: ["3000"]
    depends_on:
      postgres:
        condition: service_healthy
      migrate:
        condition: service_completed_successfully
    networks: [frontend, backend]
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/api/health').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    restart: unless-stopped
    mem_limit: 650m
    cpus: 0.75
    logging: *default-logging

  caddy:
    image: caddy:2.10.2-alpine
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      app:
        condition: service_healthy
    networks: [frontend]
    restart: unless-stopped
    mem_limit: 160m
    cpus: 0.25
    logging: *default-logging

networks:
  frontend: {}
  backend:
    internal: true

volumes:
  postgres_data: {}
  caddy_data: {}
  caddy_config: {}
'@

$composeContent = $composeContent.Replace("__RUNTIME_IMAGE__", $runtimeImage)
$composeContent = $composeContent.Replace("__MIGRATION_IMAGE__", $migrationImage)

$caddyContent = @'
uat.biblio.blon-enterprises.com {
  encode zstd gzip
  reverse_proxy app:3000
  log {
    output stdout
    format json
  }
}
'@

$utf8 = [System.Text.UTF8Encoding]::new($false)
$composeBase64 = [Convert]::ToBase64String($utf8.GetBytes($composeContent))
$caddyBase64 = [Convert]::ToBase64String($utf8.GetBytes($caddyContent))

$remoteScript = @'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

region="__REGION__"
runtime_image="__RUNTIME_IMAGE__"
migration_image="__MIGRATION_IMAGE__"
registry="__REGISTRY__"
fqdn="__FQDN__"
elastic_ip="__ELASTIC_IP__"
runtime_parameter_name="__RUNTIME_PARAMETER_NAME__"
runtime_env="/opt/blon/bibliotheque/runtime/app.env"
deploy_dir="/opt/blon/bibliotheque/deploy/uat"
backup_dir="/opt/blon/bibliotheque/backups"
compose_file="$deploy_dir/compose.yaml"
caddy_file="$deploy_dir/Caddyfile"
project_name="eblon-bibliotheque-uat"
postgres_volume="${project_name}_postgres_data"

fail() {
  echo "[ERREUR] $*" >&2
  exit 1
}

compose() {
  docker compose --env-file "$runtime_env" -f "$compose_file" "$@"
}

wait_healthy() {
  local service="$1"
  local attempts="$2"
  local container_id=""
  local health=""

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    container_id="$(compose ps -q "$service" 2>/dev/null || true)"

    if [[ -n "$container_id" ]]; then
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"

      if [[ "$health" == "healthy" ]]; then
        echo "[OK] Service sain : $service"
        return 0
      fi

      if [[ "$health" == "unhealthy" || "$health" == "exited" || "$health" == "dead" ]]; then
        compose logs --no-color --tail 120 "$service" >&2 || true
        fail "Le service $service est dans l'etat $health"
      fi
    fi

    sleep 5
  done

  compose logs --no-color --tail 120 "$service" >&2 || true
  fail "Le service $service n'est pas sain dans le delai imparti"
}

pull_image() {
  local image="$1"
  local output=""

  if ! output="$(docker pull "$image" 2>&1)"; then
    echo "$output" >&2
    fail "Telechargement impossible : $image"
  fi

  echo "[OK] Image telechargee : $image"
}

refresh_runtime_configuration() {
  local runtime_dir="/opt/blon/bibliotheque/runtime"
  local temp_file=""

  install -d -o root -g root -m 0750 "$runtime_dir"
  temp_file="$(mktemp "$runtime_dir/.app.env.XXXXXX")"
  trap 'rm -f "$temp_file"' EXIT HUP INT TERM

  aws ssm get-parameter \
    --name "$runtime_parameter_name" \
    --with-decryption \
    --query Parameter.Value \
    --output text \
    --region "$region" \
    > "$temp_file"

  [[ -s "$temp_file" ]] || fail "Le SecureString runtime recupere est vide"
  chown root:root "$temp_file"
  chmod 0600 "$temp_file"
  mv -f "$temp_file" "$runtime_env"
  trap - EXIT HUP INT TERM

  echo "[OK] Configuration runtime rechargee depuis Parameter Store"
}

command -v docker >/dev/null 2>&1 || fail "Docker est absent"
command -v aws >/dev/null 2>&1 || fail "AWS CLI est absent"
command -v base64 >/dev/null 2>&1 || fail "base64 est absent"
command -v curl >/dev/null 2>&1 || fail "curl est absent"
systemctl is-active --quiet docker.service || fail "Docker n'est pas actif"
docker compose version >/dev/null

refresh_runtime_configuration

[[ -s "$runtime_env" ]] || fail "Le fichier runtime est absent ou vide"
[[ "$(stat -c '%U:%G' "$runtime_env")" == "root:root" ]] || fail "Le proprietaire du fichier runtime est incorrect"
[[ "$(stat -c '%a' "$runtime_env")" == "600" ]] || fail "Le mode du fichier runtime n'est pas 0600"

required_keys=(
  POSTGRES_DB
  POSTGRES_USER
  POSTGRES_PASSWORD
  DATABASE_URL
  DATABASE_SCHEMA
  BETTER_AUTH_URL
  BETTER_AUTH_SECRET
  TRUSTED_ORIGINS
  NEXT_PUBLIC_APP_URL
  NODE_ENV
  PORT
  HOSTNAME
  PUBLIC_SIGNUP_ENABLED
  EMAIL_ENABLED
  EMAIL_FROM
  RESEND_API_KEY
)

for key in "${required_keys[@]}"; do
  match_count="$(grep -cE "^${key}=.+$" "$runtime_env" || true)"
  [[ "$match_count" -eq 1 ]] || fail "Variable runtime absente, vide ou dupliquee : $key"
done

grep -qE '^DATABASE_URL=postgresql://.+@postgres:5432/.+$' "$runtime_env" || fail "DATABASE_URL ne cible pas postgres:5432"
grep -qE "^BETTER_AUTH_URL=https://${fqdn}[[:space:]]*$" "$runtime_env" || fail "BETTER_AUTH_URL est incorrecte"
grep -qE "^TRUSTED_ORIGINS=https://${fqdn}[[:space:]]*$" "$runtime_env" || fail "TRUSTED_ORIGINS est incorrecte"
grep -qE "^NEXT_PUBLIC_APP_URL=https://${fqdn}[[:space:]]*$" "$runtime_env" || fail "NEXT_PUBLIC_APP_URL est incorrecte"
grep -qE '^NODE_ENV=production[[:space:]]*$' "$runtime_env" || fail "NODE_ENV doit valoir production"
grep -qE '^PUBLIC_SIGNUP_ENABLED=__PUBLIC_SIGNUP_ENABLED__[[:space:]]*$' "$runtime_env" || fail "PUBLIC_SIGNUP_ENABLED doit valoir __PUBLIC_SIGNUP_ENABLED__"
grep -qE '^EMAIL_ENABLED=true[[:space:]]*$' "$runtime_env" || fail "EMAIL_ENABLED doit valoir true"
grep -qE '^EMAIL_FROM=[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+[[:space:]]*$' "$runtime_env" || fail "EMAIL_FROM est incorrecte"
grep -qE '^RESEND_API_KEY=re_[^[:space:]]+[[:space:]]*$' "$runtime_env" || fail "RESEND_API_KEY est incorrecte"

available_kib="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
free_kib="$(df --output=avail / | tail -n 1 | tr -d ' ')"
[[ "$available_kib" -ge 1200000 ]] || fail "Moins de 1,2 Gio de memoire sont disponibles avant deploiement"
[[ "$free_kib" -ge 5242880 ]] || fail "Moins de 5 Gio sont disponibles sur le volume racine"

install -d -o root -g root -m 0750 "$deploy_dir" "$backup_dir"

printf '%s' '__COMPOSE_B64__' | base64 --decode > "$deploy_dir/.compose.yaml.new"
printf '%s' '__CADDY_B64__' | base64 --decode > "$deploy_dir/.Caddyfile.new"
test -s "$deploy_dir/.compose.yaml.new" || fail "Le fichier Compose genere est vide"
test -s "$deploy_dir/.Caddyfile.new" || fail "Le Caddyfile genere est vide"
chown root:root "$deploy_dir/.compose.yaml.new" "$deploy_dir/.Caddyfile.new"
chmod 0640 "$deploy_dir/.compose.yaml.new"
chmod 0644 "$deploy_dir/.Caddyfile.new"
mv -f "$deploy_dir/.compose.yaml.new" "$compose_file"
mv -f "$deploy_dir/.Caddyfile.new" "$caddy_file"

docker compose --env-file "$runtime_env" -f "$compose_file" config >/dev/null

aws ecr get-login-password --region "$region" \
  | docker login --username AWS --password-stdin "$registry" >/dev/null

pull_image "$runtime_image"
pull_image "$migration_image"
docker logout "$registry" >/dev/null 2>&1 || true
pull_image postgres:17.6-alpine3.22
pull_image caddy:2.10.2-alpine

[[ "$(docker image inspect --format '{{.Architecture}}' "$runtime_image")" == "amd64" ]] || fail "Architecture runtime incorrecte"
[[ "$(docker image inspect --format '{{.Architecture}}' "$migration_image")" == "amd64" ]] || fail "Architecture migration incorrecte"

compose run --rm --no-deps --entrypoint node migrate --eval \
  "const url=new URL(process.env.DATABASE_URL);const valid=decodeURIComponent(url.username)===process.env.POSTGRES_USER&&decodeURIComponent(url.password)===process.env.POSTGRES_PASSWORD&&url.hostname==='postgres'&&url.port==='5432'&&url.pathname.slice(1)===process.env.POSTGRES_DB;if(!valid)process.exit(1)"
echo "[OK] Coherence non divulguee des identifiants PostgreSQL validee"

database_already_exists=false
if docker volume inspect "$postgres_volume" >/dev/null 2>&1; then
  database_already_exists=true
fi

compose up -d postgres
wait_healthy postgres 24

if [[ "$database_already_exists" == "true" ]]; then
  backup_file="$backup_dir/postgres-before-$(date -u +%Y%m%dT%H%M%SZ).dump"
  compose exec -T postgres sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom' > "$backup_file"
  test -s "$backup_file" || fail "La sauvegarde PostgreSQL est vide"
  chmod 0600 "$backup_file"
  echo "[OK] Sauvegarde PostgreSQL creee avant migration"
else
  echo "[OK] Nouveau volume PostgreSQL initialise"
fi

compose run --rm --no-deps migrate
echo "[OK] Migrations et verification PostgreSQL terminees"

compose up -d --no-deps app
wait_healthy app 36

app_container_id="$(compose ps -q app)"
docker exec "$app_container_id" node -e \
  "fetch('http://127.0.0.1:3000/api/health').then(async response=>{const body=await response.json();if(!response.ok||body.application!=='ok'||body.database!=='ok'){console.error(JSON.stringify(body));process.exit(1)}console.log(JSON.stringify(body))}).catch(error=>{console.error(error.message);process.exit(1)})"
echo "[OK] Sante interne application et PostgreSQL validee"

dns_ready=false
for ((attempt = 1; attempt <= 40; attempt++)); do
  if getent ahostsv4 "$fqdn" 2>/dev/null | awk '{print $1}' | grep -Fxq "$elastic_ip"; then
    dns_ready=true
    break
  fi
  sleep 15
done

if [[ "$dns_ready" == "true" ]]; then
  echo "[OK] DNS public : $fqdn -> $elastic_ip"
  compose up -d --no-deps caddy

  https_ready=false
  for ((attempt = 1; attempt <= 36; attempt++)); do
    if curl --fail --silent --show-error --max-time 10 "https://${fqdn}/api/health" >/dev/null 2>&1; then
      https_ready=true
      break
    fi
    sleep 5
  done

  if [[ "$https_ready" != "true" ]]; then
    compose logs --no-color --tail 120 caddy >&2 || true
    fail "HTTPS n'est pas operationnel"
  fi

  echo "[OK] HTTPS operationnel : https://${fqdn}/api/health"
  deployment_state="HTTPS_READY"
else
  compose stop caddy >/dev/null 2>&1 || true
  echo "[ATTENTE] Application saine, mais Caddy reste arrete jusqu'a la propagation DNS"
  deployment_state="DNS_PENDING"
fi

compose ps
echo "DEPLOYMENT_STATE=$deployment_state"
echo "RUNTIME_IMAGE=$runtime_image"
echo "MIGRATION_IMAGE=$migration_image"
'@

$replacements = [ordered]@{
  "__REGION__"          = $region
  "__RUNTIME_IMAGE__"   = $runtimeImage
  "__MIGRATION_IMAGE__" = $migrationImage
  "__REGISTRY__"        = $registry
  "__FQDN__"            = $fqdn
  "__ELASTIC_IP__"      = $elasticIp
  "__RUNTIME_PARAMETER_NAME__" = $runtimeParameterName
  "__PUBLIC_SIGNUP_ENABLED__" = $publicSignupValue
  "__COMPOSE_B64__"     = $composeBase64
  "__CADDY_B64__"       = $caddyBase64
}

foreach ($replacement in $replacements.GetEnumerator()) {
  $remoteScript = $remoteScript.Replace(
    [string] $replacement.Key,
    [string] $replacement.Value
  )
}

if ($remoteScript -match '__[A-Z0-9_]+__') {
  throw "Un marqueur interne n'a pas ete remplace dans le script SSM"
}

$remoteScript = $remoteScript.Replace("`r`n", "`n").Replace("`r", "`n")
$remoteBytes = $utf8.GetBytes($remoteScript)
$compressedStream = [System.IO.MemoryStream]::new()
$gzipStream = [System.IO.Compression.GZipStream]::new(
  $compressedStream,
  [System.IO.Compression.CompressionMode]::Compress,
  $true
)

try {
  $gzipStream.Write($remoteBytes, 0, $remoteBytes.Length)
} finally {
  $gzipStream.Dispose()
}

$payload = [Convert]::ToBase64String($compressedStream.ToArray())
$compressedStream.Dispose()

$payloadChunks = @(
  [regex]::Matches($payload, '.{1,2800}') |
    ForEach-Object { $_.Value }
)

$remoteToken = [guid]::NewGuid().ToString("N")
$remotePayloadPath = "/tmp/blon-${remoteToken}.b64"
$remoteScriptPath = "/tmp/blon-${remoteToken}.sh"

$commands = @(
  "set -eu",
  "umask 077",
  "trap 'rm -f `"$remotePayloadPath`" `"$remoteScriptPath`"' EXIT",
  ": > `"$remotePayloadPath`""
)

foreach ($chunk in $payloadChunks) {
  $commands += "printf '%s' '$chunk' >> `"$remotePayloadPath`""
}

$commands += @(
  "base64 --decode `"$remotePayloadPath`" | gzip --decompress > `"$remoteScriptPath`"",
  "chmod 0700 `"$remoteScriptPath`"",
  "bash `"$remoteScriptPath`""
)

$ssmRequest = @{
  DocumentName = "AWS-RunShellScript"
  InstanceIds = @($instanceId)
  Comment = "Deploy EBLON Bibliotheque UAT a948138"
  TimeoutSeconds = 600
  Parameters = @{
    commands = $commands
    executionTimeout = @("1800")
  }
}

$requestFileName = "blon-ssm-$([guid]::NewGuid().ToString('N')).json"
$requestFilePath = Join-Path $env:TEMP $requestFileName

try {
  [System.IO.File]::WriteAllText(
    $requestFilePath,
    ($ssmRequest | ConvertTo-Json -Depth 10),
    $utf8
  )

  Push-Location $env:TEMP

  try {
    $sendOutput = @(
      aws ssm send-command `
        --cli-input-json "file://$requestFileName" `
        --region $region `
        --profile $profile `
        --output json `
        --no-cli-pager
    )
    $sendExitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }

  if ($sendExitCode -ne 0) {
    throw "Envoi de la commande SSM impossible"
  }

  $sendResult = (($sendOutput -join "`n") | ConvertFrom-Json)
  $commandId = [string] $sendResult.Command.CommandId

  Write-Host "Commande SSM envoyee : $commandId" -ForegroundColor Cyan

  $terminalStatuses = @(
    "Success",
    "Cancelled",
    "TimedOut",
    "Failed"
  )

  $invocation = $null

  for ($attempt = 1; $attempt -le 420; $attempt++) {
    $invocationOutput = @(
      aws ssm get-command-invocation `
        --command-id $commandId `
        --instance-id $instanceId `
        --region $region `
        --profile $profile `
        --output json `
        --no-cli-pager 2>$null
    )
    $invocationExitCode = $LASTEXITCODE

    if ($invocationExitCode -eq 0) {
      $invocation = (($invocationOutput -join "`n") | ConvertFrom-Json)

      if ($terminalStatuses -contains $invocation.Status) {
        break
      }
    }

    Start-Sleep -Seconds 5
  }

  if ($null -eq $invocation -or $terminalStatuses -notcontains $invocation.Status) {
    throw "La commande SSM n'a pas atteint un etat terminal dans le delai imparti"
  }

  if ($invocation.StandardOutputContent) {
    Write-Host "`n===== SORTIE DU DEPLOIEMENT =====" -ForegroundColor Cyan
    Write-Host $invocation.StandardOutputContent
  }

  if ($invocation.Status -ne "Success") {
    if ($invocation.StandardErrorContent) {
      Write-Host "`n===== ERREUR DU DEPLOIEMENT =====" -ForegroundColor Red
      Write-Host $invocation.StandardErrorContent
    }

    throw "Deploiement SSM termine avec le statut $($invocation.Status)"
  }

  Write-Host "`n[OK] Phase de deploiement terminee" -ForegroundColor Green
  Write-Host "INSTANCE_ID=$instanceId"
  Write-Host "ELASTIC_IP=$elasticIp"
  Write-Host "URL=https://$fqdn"
} finally {
  Remove-Item -LiteralPath $requestFilePath -Force -ErrorAction SilentlyContinue
}
