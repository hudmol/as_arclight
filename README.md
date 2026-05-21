# as_arclight
An ArchivesSpace plugin for syncing published data to Arclight Solr indexes.

Compatible with ArchivesSpace v4.x and Arclight v1.6.x.

Developed by Hudson Molonglo for
The Research Foundation for The State University of New York.


## Overview

This plugin defines a new indexer which operates similarly to the existing
ArchivesSpace indexers, except that it targets one or more Arclight Solr
instances.

The Arclight Solr expects a collection (ArchivesSpace Resource) to be indexed as
a single nested document. This means that if any component of the collection
changes, the entire collection must be reindexed. The plugin achieves this by
maintaining a SQLite database that stores the URIs of any Resources that have
had changes made directly or to any of their components or related records
since the last index run.

When the Arclight indexer runs an indexing round, it works sequentially through
the list of Resource URIs in the SQLite database, building up the complete
nested document for each Resource and posting it to Arclight's Solr.

This database, and another for storing cached IIIF manifests, are placed in a
directory called `as_arclight` in ArchivesSpace's data directory
(AppConfig[:data_directory]).

As with other indexers, the as_arclight indexer creates state files -
containing last indexed timestamps for record types within repositories. These
files are stored in a directory called `indexer_arclight_state`, also in
ArchivesSpace's data directory.


## Installation

1.  Download the plugin to ArchivesSpace's plugins directory.
2.  Add the plugin to the list in AppConfig:
    ```
      AppConfig[:plugins] << 'as_arclight'
    ```
3.  Configure `as_arclight` (see below)
4.  Start ArchivesSpace


## Configuration

Required configuration:
*  AppConfig[:as_arclight_solr_url]
    - The URL of an Arclight Solr instance, or an array of Solr URLs
*  AppConfig[:as_arclight_indexing_frequency_seconds]
    - Number of seconds to wait between indexing runs

Optional configuration:
*  AppConfig[:as_arclight_resource_id_prefix]
    - a string to prefix a Resource's ID with when mapping
*  AppConfig[:as_arclight_archival_object_id_prefix]
    - a string to prefix an Archival Object's ID with when mapping

Example configuration:
```
    AppConfig[:as_arclight_solr_url] = "http://localhost:8983/solr/blacklight-core"
    AppConfig[:as_arclight_indexing_frequency_seconds] = 30
    AppConfig[:as_arclight_resource_id_prefix] = 'XXX'
    AppConfig[:as_arclight_archival_object_id_prefix] = 'XXX'
```

The plugin will check the configuration on start up and raise an exception if
there are any problems.

Note that in the example, Arclight Solr is running on the default Solr port.
This is the same port that ArchivesSpace's Solr defaults to. If the two Solrs
are running on the same host, one will have to choose a non-default port.


## Customization

It is possible to customize the mapping of ArchivesSpace records to Solr docs by
creating a plugin that registers its own mappers.

[Example plugin](https://github.com/hudmol/as_arclight_custom_example)


## Notes

  * The repository that a resource gets added to in Arclight is determined
    by the repository_ssm field in its solr. This is the name of the repository
    as defined in config/repositories.yml. So, if the name of the repository
    gets changed in ArchivesSpace it will need to be changed to match in
    Arclight. This will require reindexing the whole repository.
