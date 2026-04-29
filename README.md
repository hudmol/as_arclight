# as_arclight
An ArchivesSpace plugin for syncing published data to an ArcLight Solr index.

Compatible with ArchivesSpace v4.x and ArcLight v1.6.x.

Developed by Hudson Molonglo for The Research Foundation for The State University of New York.

## Overview

This plugin defines a new indexer which operates similarly to the existing
ArchivesSpace indexers, except that it targets an Arclight Solr.

The Arclight Solr expects a collection (ArchivesSpace Resource) to be indexed as
a single nested document. This means that if any component of the collection
changes, the entire collection must be reindexed. The plugin achieves this by
maintaining a SQLite database that stores the URIs of any Resources that have
had changes made directly or to any of their components (Archival Objects)
since the last index run.

When the Arclight indexer runs an indexing round, it works sequentially through
the list of Resource URIs in the SQLite database, building up the complete
nested document for each Resource and posting it to Arclight's Solr.


## Installation

1.  Download the plugin to ArchivesSpace's plugins directory.
2.  Add the plugin to the list in AppConfig:
    ```
      AppConfig[:plugins] << 'as_arclight'
    ```
3.  Ensure we have the SQLite JDBC driver Gem.
    ```
      /path/to/archivesspace/scripts/initialize-plugin.sh as_arclight
    ```
4.  Configure `as_arclight` (see below)
5.  Start ArchivesSpace


## Configuration

Required configuration:
*  AppConfig[:as_arclight_solr_url] - The URL of an Arclight Solr instance
*  AppConfig[:as_arclight_indexing_frequency_seconds] - Number of seconds to wait between indexing runs

Optional configuration:
*  AppConfig[:as_arclight_ead_id_prefix] - a string to prefix a Resource's EAD ID with when mapping
*  AppConfig[:as_arclight_ref_id_prefix] - a string to prefix an Archival Object's Ref ID with when mapping

Example configuration:
```
    AppConfig[:as_arclight_solr_url] = "http://localhost:8983/solr/blacklight-core"
    AppConfig[:as_arclight_indexing_frequency_seconds] = 30
    AppConfig[:as_arclight_ead_id_prefix] = 'XXX'
    AppConfig[:as_arclight_ref_id_prefix] = 'XXX'
```

The plugin will check the configuration on start up and raise an exception if
there are any problems.

Note that in the example, ArcLight Solr is running on the default Solr port.
This is the same port that ArchivesSpace's Solr defaults to. If the two Solrs
are running on the same host, one will have to choose a non-default port.


## Notes

  * The repository that a resource gets added to in ArcLight is determined
    by the repository_ssm field in its solr. This is the name of the repository
    as defined in config/repositories.yml. So, if the name of the repository
    gets changed in ArchivesSpace it will need to be changed to match in
    ArcLight. This will require reindexing the whole repository.
