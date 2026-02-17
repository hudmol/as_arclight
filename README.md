# as_arclight
An ArchivesSpace plugin for syncing published data to an ArcLight Solr index.

Compatible with ArchivesSpace v4.x and ArcLight v1.6.x.

Developed by Hudson Molonglo for The Research Foundation for The State University of New York.

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

## Notes

  * The repository that a resource gets added to in ArcLight is determined
    by the repository_ssm field in its solr. This is the name of the repository
    as defined in config/repositories.yml. So, if the name of the repository
    gets changed in ArchivesSpace it will need to be changed to match in
    ArcLight. This will require reindexing the whole repository.
