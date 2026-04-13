# Lidarr HTTP client
# Required env vars: LIDARR_HOST (e.g. http://10.13.13.1:32686), LIDARR_API_KEY

def build-url [path: string, params: record = {}] {
  let base = $"($env.LIDARR_HOST)/api/v1/($path)"
  let query = $params | transpose k v | each { $"($in.k)=($in.v)" } | str join "&"
  if ($query | is-empty) { $base } else { $"($base)?($query)" }
}

def build-headers [] {
  { "X-Api-Key": $env.LIDARR_API_KEY }
}

def api-get [path: string, params: record = {}] {
  (http get (build-url $path $params)
    --full --allow-errors
    --headers (build-headers))
  | select body status
}

def api-post [path: string, body: any] {
  $body | to json
  | (http post (build-url $path)
      --full --allow-errors
      --content-type application/json
      --headers (build-headers))
  | select body status
}

def api-put [path: string, body: any] {
  $body | to json
  | (http put (build-url $path)
      --full --allow-errors
      --content-type application/json
      --headers (build-headers))
  | select body status
}

def api-delete [path: string] {
  (http delete (build-url $path)
    --full --allow-errors
    --headers (build-headers))
  | select body status
}

# --- System ---

# Get Lidarr system status (version, OS, start time, etc.)
export def "lidarr status" [] {
  api-get "system/status"
}

# List configured root folders
export def "lidarr root-folders" [] {
  api-get "rootfolder"
}

# List all quality profiles
export def "lidarr quality-profiles" [] {
  api-get "qualityprofile"
}

# List all metadata profiles
export def "lidarr metadata-profiles" [] {
  api-get "metadataprofile"
}

# List all tags
export def "lidarr tags" [] {
  api-get "tag"
}

# --- Artists ---

# List all artists in the library
export def "lidarr get artists" [] {
  api-get "artist"
}

# Get a single artist by their Lidarr ID
export def "lidarr get artist" [id: int] {
  api-get $"artist/($id)"
}

# Look up an artist on MusicBrainz. Use this to get the foreignArtistId before calling `lidarr add artist`
export def "lidarr search artist" [query: string] {
  api-get "artist/lookup" { term: $query }
}

# Add an artist to the library. foreignArtistId is the MusicBrainz artist ID (from `lidarr search artist`)
export def "lidarr add artist" [
  foreign_artist_id: string   # MusicBrainz artist ID
  --quality-profile: int = 1
  --metadata-profile: int = 1
  --root-folder: string = "/music"
  --monitored                  # monitor all albums
  --search                     # trigger search for missing albums after adding
] {
  api-post "artist" {
    foreignArtistId: $foreign_artist_id
    qualityProfileId: $quality_profile
    metadataProfileId: $metadata_profile
    rootFolderPath: $root_folder
    monitored: $monitored
    addOptions: {
      monitor: (if $monitored { "all" } else { "none" })
      searchForMissingAlbums: $search
    }
  }
}

# Remove an artist from the library by their Lidarr ID
export def "lidarr delete artist" [id: int] {
  api-delete $"artist/($id)"
}

# --- Albums ---

# List all albums, optionally filtered by artist ID
export def "lidarr get albums" [--artist: int] {
  if ($artist | is-not-empty) {
    api-get "album" { artistId: $artist }
  } else {
    api-get "album"
  }
}

# Get a single album by its Lidarr ID
export def "lidarr get album" [id: int] {
  api-get $"album/($id)"
}

# Look up an album on MusicBrainz by title or MusicBrainz ID
export def "lidarr search album" [query: string] {
  api-get "album/lookup" { term: $query }
}

# Set an album's monitored state. Use --unmonitor to stop monitoring
export def "lidarr monitor album" [id: int, --unmonitor] {
  let album = (api-get $"album/($id)" | get body)
  api-put $"album/($id)" ($album | upsert monitored (not $unmonitor))
}

# --- Tracks ---

# List all tracks for a given album ID
export def "lidarr get tracks" [album_id: int] {
  api-get "track" { albumId: $album_id }
}

# --- Queue ---

# List all items currently in the download queue
export def "lidarr queue" [] {
  api-get "queue"
}

# Remove an item from the download queue by its queue ID. Use --blacklist to also blacklist the release
export def "lidarr queue remove" [id: int, --blacklist] {
  let params = if $blacklist { { blacklist: true } } else { {} }
  (http delete (build-url $"queue/($id)" $params)
    --full --allow-errors
    --headers (build-headers))
  | select body status
}

# --- Wanted ---

# List monitored albums that are missing from the library
export def "lidarr wanted missing" [--page: int = 1, --page-size: int = 20] {
  api-get "wanted/missing" { page: $page, pageSize: $page_size }
}

# List monitored albums that do not meet the quality cutoff
export def "lidarr wanted cutoff" [--page: int = 1, --page-size: int = 20] {
  api-get "wanted/cutoff" { page: $page, pageSize: $page_size }
}

# --- History ---

# List download and import history, newest first
export def "lidarr history" [--page: int = 1, --page-size: int = 20] {
  api-get "history" { page: $page, pageSize: $page_size }
}

# --- Commands ---

# Trigger an arbitrary async command by name. Common names: RescanArtist, RefreshArtist, AlbumSearch, ArtistSearch
export def "lidarr command" [name: string, ...extra: record] {
  let body = { name: $name } | merge ($extra | first | default {})
  api-post "command" $body
}

# Refresh metadata and rescan files for an artist by their Lidarr ID
export def "lidarr refresh artist" [id: int] {
  api-post "command" { name: "RefreshArtist", artistId: $id }
}

# Trigger a search for all monitored missing albums across all artists
export def "lidarr search missing" [] {
  api-post "command" { name: "MissingAlbumSearch" }
}
