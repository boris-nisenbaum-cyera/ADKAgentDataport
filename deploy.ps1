<#
.SYNOPSIS
  Deploys ONLY this directory's agent (ADKAgentDataport) to Cloud Run and
  registers it in Agent Registry.

.DESCRIPTION
  A single-component, self-contained equivalent of
  ../Deployment_artifacts/deploy.ps1's own `Deploy-ADKAgentDataport`
  function (plus its Agent Registry registration step), extracted into
  this directory so this one agent can be deployed -- under ANY Cloud
  Run service name -- without running or modifying that shared
  5-component script at all.

  Mirrors ../Deployment_artifacts/deploy.ps1's own conventions exactly
  (env-file-then-prompt config resolution, Secret Manager for
  credentials, a two-phase deploy to bake the service's own URL into its
  Agent Card) -- the helper functions below are a deliberate COPY, not a
  shared import, consistent with every other self-contained deploy
  script in this project (e.g. ../ADKAgentDataportMarketplace/deploy.ps1,
  ../ADKAgentDataportTerraform/deploy.ps1). This script makes NO changes
  to any file in this directory -- it only reads `.env` and deploys the
  directory as-is via `gcloud run deploy --source .`.

  Unlike ../Deployment_artifacts/deploy.ps1's own hardcoded
  "cyera-dataport-agent" service name, -ServiceName here can be anything
  you want -- deploy multiple independent copies of this same agent
  (e.g. per-environment, per-team, or side-by-side with the one
  ../Deployment_artifacts/deploy.ps1 already created) without colliding.
  -ServiceId and -DisplayName (both Agent Registry fields) default to
  -ServiceName for the same reason -- override them independently if you
  want a registry display name that differs from the raw Cloud Run
  service name.

.PARAMETER Project
  GCP project ID. If omitted, read from this directory's own `.env`
  (GOOGLE_CLOUD_PROJECT), else prompted.

.PARAMETER Region
  Cloud Run region. Default: us-central1.

.PARAMETER ServiceName
  Cloud Run service name -- the "assign any name" knob. Default:
  cyera-dataport-agent (same name ../Deployment_artifacts/deploy.ps1
  uses, so the default behavior matches that script's own).

.PARAMETER ServiceId
  Agent Registry service ID this agent registers/updates under. Default:
  same value as -ServiceName -- keeps a renamed deployment from
  colliding with another deployment of this same agent under a
  different name.

.PARAMETER DisplayName
  Agent Registry display name. Default: same value as -ServiceName.

.PARAMETER IdentityPlatformProjectId
  GCP/Firebase project ID Identity Platform ID tokens must carry as
  `aud` (see auth_middleware.py). Default: same as -Project.

.PARAMETER GeminiEnterpriseProjectNumber
  If set (or present in `.env` as GEMINI_ENTERPRISE_PROJECT_NUMBER),
  grants roles/run.invoker on this --no-allow-unauthenticated service to
  Gemini Enterprise's own Discovery Engine service agent, so its Agent
  Gateway can call this agent. Optional -- leave unset to skip.

.PARAMETER ExtraInvokerMembers
  Repeatable extra "serviceAccount:..."/"user:..." principal to grant
  roles/run.invoker, on top of the project's own compute default service
  account (always granted).

.PARAMETER SkipRegistration
  Deploy only -- skip register_agent_registry.py.

.PARAMETER AutoGrantRegistrationImpersonation
  Off by default. register_agent_registry.py needs to fetch this agent's
  own Agent Card over HTTPS, but since this service is deployed
  --no-allow-unauthenticated, that requires a Cloud-Run-IAM-scoped
  identity token -- a human `gcloud auth login` user account can only
  get one by impersonating the project's compute default service
  account, which in turn requires roles/iam.serviceAccountTokenCreator
  on it (a permission most roles, including roles/owner, do not include
  by default). If this switch is passed AND that permission is missing
  for whoever is currently running this script, it is granted
  automatically before the registration step runs. Left off by default
  because granting a new IAM permission to the current user is a
  meaningfully different kind of action than everything else this script
  does on its own (which only ever touches the newly-deployed
  resources, never the caller's own permissions) -- without this switch,
  a registration failure instead prints the exact manual command to run
  (see README.md's own "If Agent Registry registration fails" section).

.PARAMETER DryRun
  Print every gcloud/python command this script would run, execute none
  of them.

.EXAMPLE
  .\deploy.ps1 -Project my-project
  Deploys as "cyera-dataport-agent" (the default name), registers it in
  Agent Registry under the same ID.

.EXAMPLE
  .\deploy.ps1 -Project my-project -ServiceName cyera-dataport-agent-qa
  Deploys a second, independent copy under a different Cloud Run service
  name -- registers under Agent Registry service ID
  "cyera-dataport-agent-qa" too, so it doesn't collide with the default
  deployment's own registry entry.

.EXAMPLE
  .\deploy.ps1 -Project my-project -DryRun
  Preview every command without changing anything.
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Region = "us-central1",
    [string]$ServiceName = "cyera-dataport-agent",
    [string]$ServiceId,
    [string]$DisplayName,
    [string]$IdentityPlatformProjectId,
    [string]$GeminiEnterpriseProjectNumber,
    [string[]]$ExtraInvokerMembers = @(),
    [switch]$SkipRegistration,
    [switch]$AutoGrantRegistrationImpersonation,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$Script:DryRun = [bool]$DryRun
$Script:SkipRegistration = [bool]$SkipRegistration
$Script:AutoGrantRegistrationImpersonation = [bool]$AutoGrantRegistrationImpersonation
$Script:ScriptRoot = $PSScriptRoot

if (-not $ServiceId) { $ServiceId = $ServiceName }
if (-not $DisplayName) { $DisplayName = $ServiceName }

# ---------------------------------------------------------------------
# .env parsing / interactive config resolution
# (copied from ../Deployment_artifacts/deploy.ps1 -- see this script's
# own module docstring for why this is a copy, not a shared import)
# ---------------------------------------------------------------------

function Read-DotEnvFile {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) { continue }
        $key = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        if ($value.Length -ge 2) {
            $isDouble = $value.StartsWith('"') -and $value.EndsWith('"')
            $isSingle = $value.StartsWith("'") -and $value.EndsWith("'")
            if ($isDouble -or $isSingle) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        if ($value -ne "") {
            $result[$key] = $value
        }
    }
    return $result
}

function Resolve-ConfigValue {
    <# The single place every "where does this value come from" decision
       is made:
         1. $EnvTable[$Key] if present and non-empty.
         2. Else, if -Silent: $Default (no prompt at all).
         3. Else: an interactive prompt, masked if -Secret, pre-filled
            with $Default if given (press Enter to accept), otherwise
            required (re-prompts until non-empty). #>
    param(
        [hashtable]$EnvTable,
        [string]$Key,
        [string]$Default = $null,
        [string]$HintFile = $null,
        [switch]$Secret,
        [switch]$Silent
    )
    if ($EnvTable -and $EnvTable.ContainsKey($Key) -and $EnvTable[$Key]) {
        return $EnvTable[$Key]
    }
    if ($Silent) {
        return $Default
    }
    if ($HintFile) {
        Write-Host "  (Could not find $Key in $HintFile)" -ForegroundColor DarkYellow
    } else {
        Write-Host "  ($Key could not be determined automatically)" -ForegroundColor DarkYellow
    }
    $maxAttempts = 5
    if ($Secret) {
        $secure = Read-Host -Prompt "  Enter $Key" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $attempt = 0
        while ([string]::IsNullOrWhiteSpace($plain)) {
            $attempt++
            if ($attempt -ge $maxAttempts) {
                Write-Error "No value received for $Key after $maxAttempts attempts (no interactive input available?). Aborting."
                exit 1
            }
            Write-Host "  $Key is required." -ForegroundColor Red
            $secure = Read-Host -Prompt "  Enter $Key" -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            } finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
        return $plain
    }
    if ($Default) {
        $entered = Read-Host -Prompt "  Enter $Key [$Default]"
        if ([string]::IsNullOrWhiteSpace($entered)) { return $Default }
        return $entered
    }
    $entered = Read-Host -Prompt "  Enter $Key"
    $attempt = 0
    while ([string]::IsNullOrWhiteSpace($entered)) {
        $attempt++
        if ($attempt -ge $maxAttempts) {
            Write-Error "No value received for $Key after $maxAttempts attempts (no interactive input available?). Aborting."
            exit 1
        }
        Write-Host "  $Key is required." -ForegroundColor Red
        $entered = Read-Host -Prompt "  Enter $Key"
    }
    return $entered
}

# ---------------------------------------------------------------------
# Secret Manager helpers (idempotent -- re-running never rotates an
# already-existing secret out from under existing clients)
# ---------------------------------------------------------------------

function Invoke-GcloudQuiet {
    param([string[]]$GcloudArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & gcloud @GcloudArgs 2>$null
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Test-SecretExists {
    param([string]$Name, [string]$Project)
    Invoke-GcloudQuiet -GcloudArgs @("secrets", "describe", $Name, "--project=$Project") | Out-Null
    return $LASTEXITCODE -eq 0
}

function Set-DeploymentSecret {
    param([string]$Name, [string]$Project, [string]$Value)
    $exists = Test-SecretExists -Name $Name -Project $Project
    if ($exists) {
        Write-Host "  Secret '$Name' already exists -- reusing its current value." -ForegroundColor DarkGray
        return
    }
    if ($Script:DryRun) {
        Write-Host "  [DRY RUN] gcloud secrets create $Name --project=$Project --data-file=<value>"
        return
    }
    $tmp = New-TemporaryFile
    try {
        Set-Content -Path $tmp -NoNewline -Value $Value
        & gcloud secrets create $Name --project=$Project --replication-policy=automatic --data-file="$tmp" | Out-Null
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

function Grant-SecretAccess {
    param([string]$Name, [string]$Project, [string]$ServiceAccount)
    if ($Script:DryRun) {
        Write-Host "  [DRY RUN] gcloud secrets add-iam-policy-binding $Name --project=$Project --member=serviceAccount:$ServiceAccount --role=roles/secretmanager.secretAccessor"
        return
    }
    & gcloud secrets add-iam-policy-binding $Name --project=$Project --member="serviceAccount:$ServiceAccount" --role="roles/secretmanager.secretAccessor" | Out-Null
}

function Get-ComputeServiceAccount {
    param([string]$Project)
    $projectNumber = (& gcloud projects describe $Project --format="value(projectNumber)")
    return "$projectNumber-compute@developer.gserviceaccount.com"
}

function Grant-AgentInvokerAccess {
    <# Grants roles/run.invoker on a --no-allow-unauthenticated agent
       service to each of $Members. Idempotent -- re-running an existing
       binding is a harmless no-op. #>
    param([string]$Service, [string]$Region, [string]$Project, [string[]]$Members)
    foreach ($member in $Members) {
        if (-not $member) { continue }
        if ($Script:DryRun) {
            Write-Host "  [DRY RUN] gcloud run services add-iam-policy-binding $Service --region=$Region --project=$Project --member=$member --role=roles/run.invoker"
            continue
        }
        & gcloud run services add-iam-policy-binding $Service --region=$Region --project=$Project --member="$member" --role="roles/run.invoker" | Out-Null
    }
}

function Resolve-ModelCredentialConfig {
    <# Every ADK agent's own .env.example documents TWO mutually
       exclusive model-credential modes: "Option A" (GOOGLE_API_KEY, an
       AI Studio key) or "Option B" (Vertex AI -- GOOGLE_GENAI_USE_VERTEXAI
       + GOOGLE_CLOUD_PROJECT/LOCATION). Returns
       @{ EnvVars = "..."; Secrets = "" or "GOOGLE_API_KEY=...:latest" }.

       VERTEX_MODEL_LOCATION -- a deliberately DIFFERENT config key from
       GOOGLE_CLOUD_LOCATION -- overrides the Vertex AI MODEL endpoint's
       own location, falling back to $Region (the Cloud Run deploy
       region) only if not set in `.env`. A real, live-confirmed
       necessity: this agent's own default model (gemini-3.8-flash) is
       only served via Vertex AI's "global" endpoint, NOT us-central1 --
       yet Cloud Run itself still needs to deploy to a real region, a
       completely different Google Cloud concept from where the MODEL is
       served. See this directory's own README.md, "Configuring the
       LLM" section, for the full explanation. #>
    param([hashtable]$EnvTable, [string]$Service, [string]$Project, [string]$Region)
    $apiKey = Resolve-ConfigValue -EnvTable $EnvTable -Key "GOOGLE_API_KEY" -Default $null -Silent
    if ($apiKey) {
        $secretName = "$Service-google-api-key"
        Set-DeploymentSecret -Name $secretName -Project $Project -Value $apiKey
        Grant-SecretAccess -Name $secretName -Project $Project -ServiceAccount (Get-ComputeServiceAccount -Project $Project)
        return @{
            EnvVars = "GOOGLE_CLOUD_PROJECT=$Project"
            Secrets = "GOOGLE_API_KEY=${secretName}:latest"
        }
    }
    $modelLocation = Resolve-ConfigValue -EnvTable $EnvTable -Key "VERTEX_MODEL_LOCATION" -Default $Region -Silent
    return @{
        EnvVars = "GOOGLE_GENAI_USE_VERTEXAI=true,GOOGLE_CLOUD_PROJECT=$Project,GOOGLE_CLOUD_LOCATION=$modelLocation"
        Secrets = ""
    }
}

function Join-NonEmpty {
    param([string[]]$Parts)
    return (($Parts | Where-Object { $_ }) -join ",")
}

# ---------------------------------------------------------------------
# Cloud Run deploy helpers
# ---------------------------------------------------------------------

function Get-ServiceUrl {
    param([string]$Service, [string]$Region, [string]$Project)
    return (& gcloud run services describe $Service --region=$Region --project=$Project --format="value(status.url)")
}

function Invoke-RunDeploy {
    <# $ExtraArgs is an array of already-tokenized arguments. Returns the
       deployed service's URL.

       --timeout is always passed explicitly (600s -- Cloud Run's own
       platform default is 300s) -- matches
       ../Deployment_artifacts/deploy.ps1's identical, live-confirmed
       fix (a complex multi-round request was observed to exceed the
       platform's own 300s default). #>
    param(
        [string]$Service,
        [string]$SourceDir,
        [string]$Region,
        [string]$Project,
        [string[]]$ExtraArgs = @(),
        [int]$TimeoutSeconds = 600,
        [switch]$RequireAuth
    )
    # RequireAuth: this agent's real gate is IdentityPlatformAuthMiddleware
    # inside the container (see auth_middleware.py); --no-allow-unauthenticated
    # at the Cloud Run/IAM layer is the real fix that lets
    # X-Serverless-Authorization (Gemini Enterprise's Agent Gateway
    # credential, or another in-project caller) actually be verified --
    # Cloud Run strips/invalidates a caller-supplied token's signature for
    # any --allow-unauthenticated service. See Grant-AgentInvokerAccess
    # for the IAM bindings this requires.
    $authFlag = if ($RequireAuth) { "--no-allow-unauthenticated" } else { "--allow-unauthenticated" }
    $gcloudArgs = @("run", "deploy", $Service, "--source", $SourceDir, "--region", $Region, "--project", $Project, $authFlag, "--timeout=$TimeoutSeconds") + $ExtraArgs
    if ($Script:DryRun) {
        Write-Host "  [DRY RUN] gcloud $($gcloudArgs -join ' ')"
        return "https://$Service-dry-run-placeholder.a.run.app"
    }
    Write-Host "  Running: gcloud $($gcloudArgs -join ' ')" -ForegroundColor Cyan
    & gcloud @gcloudArgs
    if ($LASTEXITCODE -ne 0) {
        throw "gcloud run deploy failed for service '$Service' (exit code $LASTEXITCODE)."
    }
    return (Get-ServiceUrl -Service $Service -Region $Region -Project $Project)
}

function Invoke-TwoPhaseAgentDeploy {
    <# Deploys this agent twice: once to learn its own Cloud Run URL,
       then again with A2A_HOST/A2A_PORT/A2A_PROTOCOL set to that URL so
       the public Agent Card advertises the real address -- see
       main.py's own module docstring for why this is necessary (the URL
       isn't known until after the first deploy). #>
    param(
        [string]$Service,
        [string]$SourceDir,
        [string]$Region,
        [string]$Project,
        [string]$EnvVars = $null,
        [string]$Secrets = $null,
        [switch]$RequireAuth
    )
    $extra1 = @()
    if ($Secrets) { $extra1 += @("--set-secrets", $Secrets) }
    if ($EnvVars) { $extra1 += @("--set-env-vars", $EnvVars) }

    Write-Host "  Phase 1/2: deploying $Service (learning its URL)..." -ForegroundColor Cyan
    $url = Invoke-RunDeploy -Service $Service -SourceDir $SourceDir -Region $Region -Project $Project -ExtraArgs $extra1 -RequireAuth:$RequireAuth

    $hostName = ($url -replace '^https?://', '').TrimEnd('/')
    $envVarsPhase2 = "A2A_HOST=$hostName,A2A_PORT=443,A2A_PROTOCOL=https"
    if ($EnvVars) { $envVarsPhase2 = "$EnvVars,$envVarsPhase2" }

    $extra2 = @()
    if ($Secrets) { $extra2 += @("--set-secrets", $Secrets) }
    $extra2 += @("--set-env-vars", $envVarsPhase2)

    Write-Host "  Phase 2/2: redeploying $Service with A2A_HOST set..." -ForegroundColor Cyan
    return (Invoke-RunDeploy -Service $Service -SourceDir $SourceDir -Region $Region -Project $Project -ExtraArgs $extra2 -RequireAuth:$RequireAuth)
}

# ---------------------------------------------------------------------
# Agent Registry registration
# ---------------------------------------------------------------------

function Test-UserHasServiceAccountTokenCreator {
    param([string]$ServiceAccount, [string]$Member)
    $policyJson = Invoke-GcloudQuiet -GcloudArgs @("iam", "service-accounts", "get-iam-policy", $ServiceAccount, "--format=json")
    if (-not $policyJson) { return $false }
    try {
        $policy = ($policyJson -join "`n") | ConvertFrom-Json
    } catch {
        return $false
    }
    foreach ($binding in $policy.bindings) {
        if ($binding.role -eq "roles/iam.serviceAccountTokenCreator" -and $binding.members -contains $Member) {
            return $true
        }
    }
    return $false
}

function Ensure-RegistrationImpersonationPermission {
    <# Off unless -AutoGrantRegistrationImpersonation was passed -- see
       that parameter's own help text above for the full rationale. When
       on, grants the CURRENT gcloud user roles/iam.serviceAccountTokenCreator
       on $ComputeServiceAccount, but only if needed: skipped entirely
       for an already-service-account identity (it has a direct path
       already), and skipped if the permission is already present
       (checked live -- re-running this is a harmless no-op). #>
    param([string]$Project, [string]$ComputeServiceAccount)

    if (-not $Script:AutoGrantRegistrationImpersonation) { return }

    $currentAccount = (& gcloud config get-value account 2>$null)
    if (-not $currentAccount) { return }
    if ($currentAccount -like "*.gserviceaccount.com") {
        return
    }

    $member = "user:$currentAccount"
    if (Test-UserHasServiceAccountTokenCreator -ServiceAccount $ComputeServiceAccount -Member $member) {
        Write-Host "  '$currentAccount' can already impersonate '$ComputeServiceAccount' -- nothing to grant." -ForegroundColor DarkGray
        return
    }

    if ($Script:DryRun) {
        Write-Host "  [DRY RUN] gcloud iam service-accounts add-iam-policy-binding $ComputeServiceAccount --project=$Project --member=$member --role=roles/iam.serviceAccountTokenCreator"
        return
    }

    Write-Host "  -AutoGrantRegistrationImpersonation was passed -- granting '$currentAccount' permission to impersonate '$ComputeServiceAccount' so register_agent_registry.py can fetch this agent's Agent Card..." -ForegroundColor Cyan
    $grantArgs = @("iam", "service-accounts", "add-iam-policy-binding", $ComputeServiceAccount, "--project=$Project", "--member=$member", "--role=roles/iam.serviceAccountTokenCreator")
    Invoke-GcloudQuiet -GcloudArgs $grantArgs | Out-Null
    $grantSucceeded = ($LASTEXITCODE -eq 0)
    if (-not $grantSucceeded) {
        Write-Host "  WARNING: the grant did not succeed -- '$currentAccount' likely lacks permission to modify this service account's own IAM policy. Registration below may still fail; see README.md's 'If Agent Registry registration fails' section for the manual command." -ForegroundColor Red
        return
    }

    # IAM bindings are not instantaneously consistent -- confirmed live,
    # took roughly 20-30s in practice. Poll briefly before returning
    # rather than letting the registration step below hit the same
    # propagation race immediately after this grant.
    Write-Host "  Granted. Waiting for IAM propagation..." -ForegroundColor DarkGray
    for ($i = 1; $i -le 10; $i++) {
        Start-Sleep -Seconds 6
        $probeArgs = @("auth", "print-identity-token", "--impersonate-service-account=$ComputeServiceAccount", "--audiences=https://example.com")
        if (Invoke-GcloudQuiet -GcloudArgs $probeArgs) {
            Write-Host "  Confirmed -- impersonation now works." -ForegroundColor DarkGray
            return
        }
    }
    Write-Host "  WARNING: granted, but still not propagated after 60s. Re-run this script if registration fails once more." -ForegroundColor Red
}

function Invoke-RegistrationScript {
    <# Runs register_agent_registry.py's --dry-run then real invocation.
       $ExtraArgs is where --project/--card-url/--service-id/
       --display-name are passed explicitly -- without this, the script
       would silently fall back to its OWN hardcoded default
       project/URL/service-id regardless of what THIS run actually
       deployed to. #>
    param([string]$Dir, [string]$ScriptName, [string[]]$ExtraArgs = @())
    $scriptPath = Join-Path $Dir $ScriptName
    if (-not (Test-Path $scriptPath)) {
        Write-Host "  $ScriptName not found in $Dir -- nothing to register." -ForegroundColor DarkGray
        return
    }
    if ($Script:SkipRegistration) {
        Write-Host "  Skipping $ScriptName (-SkipRegistration)." -ForegroundColor DarkGray
        return
    }
    if ($Script:DryRun) {
        Write-Host "  [DRY RUN] python $ScriptName $($ExtraArgs -join ' ') --dry-run   (then, if it looks right: python $ScriptName $($ExtraArgs -join ' '))"
        return
    }
    Push-Location $Dir
    try {
        Write-Host "  Registering via $ScriptName ..." -ForegroundColor Cyan
        # | Out-Host (not left bare) -- see
        # ../Deployment_artifacts/deploy.ps1's identical comment for the
        # real, live-confirmed corruption this avoids (python's own
        # stdout otherwise silently gets appended to this function's
        # return value, corrupting a subsequent --set-env-vars string).
        & python $ScriptName @ExtraArgs --dry-run | Out-Host
        & python $ScriptName @ExtraArgs | Out-Host
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Error "gcloud CLI not found on PATH. Install the Google Cloud SDK first."
    exit 1
}

$authToken = Invoke-GcloudQuiet -GcloudArgs @("auth", "print-access-token")
if (-not $authToken) {
    Write-Error "Not authenticated with gcloud. Run 'gcloud auth login' first."
    exit 1
}

$envFile = Join-Path $Script:ScriptRoot ".env"
$envTable = Read-DotEnvFile -Path $envFile

if (-not $Project) {
    $Project = Resolve-ConfigValue -EnvTable $envTable -Key "GOOGLE_CLOUD_PROJECT" -HintFile $envFile
}
if (-not $IdentityPlatformProjectId) {
    $IdentityPlatformProjectId = Resolve-ConfigValue -EnvTable $envTable -Key "IDENTITY_PLATFORM_PROJECT_ID" -Default $Project -Silent
}
if (-not $GeminiEnterpriseProjectNumber) {
    $GeminiEnterpriseProjectNumber = Resolve-ConfigValue -EnvTable $envTable -Key "GEMINI_ENTERPRISE_PROJECT_NUMBER" -Default $null -Silent
}

if ($Script:DryRun) {
    Write-Host "*** DRY RUN -- no gcloud/python command below actually changes anything. ***`n" -ForegroundColor Yellow
}
Write-Host "Project: $Project   Region: $Region   Service name: $ServiceName`n" -ForegroundColor Green

$sa = Get-ComputeServiceAccount -Project $Project

$mcpToken = Resolve-ConfigValue -EnvTable $envTable -Key "CYERA_DATAPORT_MCP_TOKEN" -HintFile $envFile -Secret
$mcpSecretName = "$ServiceName-mcp-token"
Set-DeploymentSecret -Name $mcpSecretName -Project $Project -Value $mcpToken
Grant-SecretAccess -Name $mcpSecretName -Project $Project -ServiceAccount $sa
$dataportSecretsArg = "CYERA_DATAPORT_MCP_TOKEN=${mcpSecretName}:latest"

$modelConfig = Resolve-ModelCredentialConfig -EnvTable $envTable -Service $ServiceName -Project $Project -Region $Region
$envVars = Join-NonEmpty @($modelConfig.EnvVars, "IDENTITY_PLATFORM_PROJECT_ID=$IdentityPlatformProjectId")
$dataportUrl = Resolve-ConfigValue -EnvTable $envTable -Key "CYERA_DATAPORT_MCP_URL" -Default $null -Silent
if ($dataportUrl) { $envVars = "$envVars,CYERA_DATAPORT_MCP_URL=$dataportUrl" }
$adkModel = Resolve-ConfigValue -EnvTable $envTable -Key "ADK_MODEL" -Default $null -Silent
if ($adkModel) { $envVars = "$envVars,ADK_MODEL=$adkModel" }
$thinkingBudget = Resolve-ConfigValue -EnvTable $envTable -Key "THINKING_BUDGET" -Default $null -Silent
if ($thinkingBudget) { $envVars = "$envVars,THINKING_BUDGET=$thinkingBudget" }
# Always paired with -RequireAuth below (never independently) -- tells
# auth_middleware.py it can trust Cloud Run's own platform-level caller
# verification. See that module's docstring for the full rationale.
$envVars = "$envVars,CLOUD_RUN_IAM_GATED=true"
$secretsArg = Join-NonEmpty @($dataportSecretsArg, $modelConfig.Secrets)

$url = Invoke-TwoPhaseAgentDeploy -Service $ServiceName -SourceDir $Script:ScriptRoot -Region $Region -Project $Project -EnvVars $envVars -Secrets $secretsArg -RequireAuth
Write-Host "$ServiceName deployed: $url" -ForegroundColor Green

$invokerMembers = @("serviceAccount:$sa") + $ExtraInvokerMembers
if ($GeminiEnterpriseProjectNumber) {
    $invokerMembers += "serviceAccount:service-$GeminiEnterpriseProjectNumber@gcp-sa-discoveryengine.iam.gserviceaccount.com"
}
Grant-AgentInvokerAccess -Service $ServiceName -Region $Region -Project $Project -Members $invokerMembers

if (-not $Script:SkipRegistration) {
    Ensure-RegistrationImpersonationPermission -Project $Project -ComputeServiceAccount $sa
}

Invoke-RegistrationScript -Dir $Script:ScriptRoot -ScriptName "register_agent_registry.py" -ExtraArgs @(
    "--project", $Project,
    "--card-url", "$url/.well-known/agent-card.json",
    "--service-id", $ServiceId,
    "--display-name", $DisplayName
)

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Agent Card: $url/.well-known/agent-card.json" -ForegroundColor Green
Write-Host "Agent Registry service ID: $ServiceId" -ForegroundColor Green

# Explicit success exit code -- without this, the process's exit code
# would just inherit whatever $LASTEXITCODE happened to be left over
# from the last native gcloud call (which can be a benign nonzero, e.g.
# Test-SecretExists's own internal "does this secret already exist"
# check returning 1 because it genuinely doesn't exist yet), not a
# reliable signal of this script's own overall success. Confirmed by
# trial: a fully successful run (including a clean -DryRun) printed
# every line above but still exited 1 before this was added -- the exact
# same bug ../Deployment_artifacts/deploy.ps1 already hit and fixed the
# same way (see that script's own identical comment at its very end).
exit 0
