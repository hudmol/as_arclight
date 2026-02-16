# as_arclight
An ArchivesSpace plugin for syncing published data to ArcLight

## Installation

The usual. Note that it needs a gem.

## Configuration

The plugin creates a new indexer, which requires configuration.

Example:
```
    AppConfig[:arclight_solr_url] = "http://localhost:8983/solr/blacklight-core"
    AppConfig[:arclight_indexing_frequency_seconds] = 30
```

Note that in the example, ArcLight Solr is running on the default Solr port.
This is the same port that ArchivesSpace's Solr defaults to. Someone is going
to have to move!
