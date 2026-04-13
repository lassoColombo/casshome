# Prowlarr HTTP client
# Required env vars: PROWLARR_HOST (e.g. http://10.13.13.1:32696), PROWLARR_API_KEY

def build-url [path: string, params: record = {}] {
  let base = $"($env.PROWLARR_HOST)/api/v1/($path)"
  let query = $params | transpose k v | each { $"($in.k)=($in.v)" } | str join "&"
  if ($query | is-empty) { $base } else { $"($base)?($query)" }
}

def build-headers [] {
  { "X-Api-Key": $env.PROWLARR_API_KEY }
}

def api-get [path: string, params: record = {}] {
  http get (build-url $path $params)
    --full --allow-errors
    --headers (build-headers)
  | select body status
}

def api-post [path: string, body: any] {
  $body | to json
  | http post (build-url $path)
      --full --allow-errors
      --content-type application/json
      --headers (build-headers)
  | select body status
}

def api-put [path: string, body: any] {
  $body | to json
  | http put (build-url $path)
      --full --allow-errors
      --content-type application/json
      --headers (build-headers)
  | select body status
}

def api-delete [path: string] {
  http delete (build-url $path)
    --full --allow-errors
    --headers (build-headers)
  | select body status
}

# --- System ---

# Get Prowlarr system status (version, OS, start time, etc.)
export def "prowlarr status" [] {
  api-get "system/status"
}

# List all tags
export def "prowlarr tags" [] {
  api-get "tag"
}

# --- Indexers ---

# List all configured indexers
export def "prowlarr get indexers" [] {
  api-get "indexer"
}

# Get a single indexer by its Prowlarr ID
export def "prowlarr get indexer" [id: int] {
  api-get $"indexer/($id)"
}

# List all available indexer definitions (useful for adding new indexers)
export def "prowlarr indexer schema" [] {
  api-get "indexer/schema"
}

# Remove an indexer by its Prowlarr ID
export def "prowlarr delete indexer" [id: int] {
  api-delete $"indexer/($id)"
}

# Test connectivity for a single indexer by its Prowlarr ID
export def "prowlarr test indexer" [id: int] {
  api-post $"indexer/($id)/test" {}
}

# Test connectivity for all configured indexers at once
export def "prowlarr test all indexers" [] {
  api-post "indexer/testall" {}
}

# --- Search ---

# Search across all (or a specific) indexer. type must be one of: search, tvsearch, moviesearch, music, book
export def "prowlarr search" [
  query: string
  --type: string = "search"   # search | tvsearch | moviesearch | music | book
  --indexer: int              # limit search to a specific indexer ID
  --limit: int = 100
  --offset: int = 0
] {
  mut params = { query: $query, type: $type, limit: $limit, offset: $offset }
  if ($indexer | is-not-empty) {
    $params = $params | insert indexerIds $indexer
  }
  api-get "search" $params
}

# --- History ---

# List grab history across all indexers, newest first
export def "prowlarr history" [--page: int = 1, --page-size: int = 20] {
  api-get "history" { page: $page, pageSize: $page_size }
}

# --- Applications (linked *arr apps) ---

# List all linked applications (e.g. Lidarr, Radarr, Sonarr)
export def "prowlarr get apps" [] {
  api-get "application"
}

# Get a single linked application by its Prowlarr ID
export def "prowlarr get app" [id: int] {
  api-get $"application/($id)"
}

# Remove a linked application by its Prowlarr ID
export def "prowlarr delete app" [id: int] {
  api-delete $"application/($id)"
}

# Push the current indexer configuration to all linked applications
export def "prowlarr sync apps" [] {
  api-post "command" { name: "ApplicationIndexerSync" }
}

# --- Download Clients ---

# List all configured download clients
export def "prowlarr get download-clients" [] {
  api-get "downloadclient"
}

# --- Stats ---

# Get per-indexer grab and query statistics
export def "prowlarr stats" [] {
  api-get "indexerstats"
}

# --- Commands ---

# Trigger an arbitrary async command by name
export def "prowlarr command" [name: string] {
  api-post "command" { name: $name }
}

# Trigger an immediate backup of the Prowlarr database and config
export def "prowlarr backup" [] {
  api-post "command" { name: "BackupNow" }
}
