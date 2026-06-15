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
*  AppConfig[:as_arclight_solr_targets]
    - An array of hashes containing the definitions of Solr instances to target.
      Each hash must have a :url key containing the URL of the Solr instance.
      A definition may also optionally include:
        - :label - a name for the instance. This will appear in the logs in place of the url
        - :user - the username for basic authentication
        - :pass - the password for basic authentication

*  AppConfig[:as_arclight_indexing_frequency_seconds]
    - Number of seconds to wait between indexing runs

Optional configuration:
*  AppConfig[:as_arclight_resource_id_prefix]
    - a string to prefix a Resource's ID with when mapping
*  AppConfig[:as_arclight_archival_object_id_prefix]
    - a string to prefix an Archival Object's ID with when mapping
*  AppConfig[:as_arclight_iiif_min_cache_seconds]
    - the minimum number of seconds to cache a URL's contents when
      fetching IIIF resources.  If unset, relies on the IIIF server's
      `Expires` and `Cache-Control` headers for guidance, defaulting
      to never caching.
*  AppConfig[:as_arclight_test_pristine_directory]
    - If `AppConfig[:as_arclight_test_mode]` is set to
      `:record_pristine`, mapped Solr documents will be written to
      this directory prior to being sent to Solr.
*  AppConfig[:as_arclight_test_mode]
    - If `AppConfig[:as_arclight_test_mode]` is set to
      `:record_candidate`, mapped Solr documents will be written to
      this directory prior to being sent to Solr.
*  AppConfig[:as_arclight_test_mode]
    - If set, should be one of `:record_pristine` or
      `:record_candidate`.  See the "Testing Your Mappings" section
      below for more information.
*  AppConfig[:include_dadocm_required_fields]
    - If true then map DadoCM required fields for digital objects
*  AppConfig[:as_arclight_reset_queue_on_start]
    - If true then the resource table will be emptied on start up


Example minimal configuration:
```
    AppConfig[:as_arclight_solr_targets] = [{:url => "http://localhost:8983/solr/blacklight-core"}]
    AppConfig[:as_arclight_indexing_frequency_seconds] = 30
```

Example target configuration including as label and basic authentication:
```
    AppConfig[:as_arclight_solr_targets] = [
        {
            :label => 'Minimal Solr target',
            :url => "http://localhost:8983/solr/blacklight-core"
        },
        {
            :label => 'Solr target with label and basic auth',
            :url => "http://authenticated_solr_host.com:8983/solr/blacklight-core",
            :user => 'solr',
            :pass => 'SolrRocks'
        }
    ]
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


## Run the unit tests

The plugin has a suite of unit tests. Run them like this:
```
    ./tests/run_tests.sh
```


## Testing Your Mappings

Using the `AppConfig[:as_arclight_test_mode]` option, you can check
whether the mapped versions of your records are what you expect.  The
basic workflow is:

  * Record the "pristine" versions of your mapped records:

    Start ArchivesSpace with the `as_arclight` plugin loaded, and the
    following configuration set:

         AppConfig[:as_arclight_test_mode] = :record_pristine

         # Directory will be created if it doesn't exist.  Just needs
         # to be somewhere writeable by the user running ArchivesSpace.
         AppConfig[:as_arclight_test_pristine_directory] = "/tmp/as_arclight_pristine"

  * Save some records in ArchivesSpace to trigger them to be reindexed
    into Arclight.  As this happens, a copy of each Resource record
    will be captured into your
    `AppConfig[:as_arclight_test_pristine_directory]` directory.

  * Remove (or comment out) the `AppConfig[:as_arclight_test_mode]`
    line from your configuration and restart ArchivesSpace.

Now you have a saved copy of your mapped records that you can use as a
baseline when checking future changes.  For example, you might use
this to verify that changing your mapping only changed your records in
the ways you expect.  Or, you might use it to verify that an upgraded
version of ArchivesSpace hasn't affected your mapped records at all.
To do that:

  * Record the "candidate" versions of your mapped records:

    Start ArchivesSpace with the `as_arclight` plugin loaded, and the
    following configuration set:

         AppConfig[:as_arclight_test_mode] = :record_candidate

         # Directory will be created if it doesn't exist.  Just needs
         # to be somewhere writeable by the user running ArchivesSpace.
         AppConfig[:as_arclight_test_candidate_directory] = "/tmp/as_arclight_candidate"

  * Save some records in ArchivesSpace to trigger them to be reindexed
    into Arclight.  As this happens, a copy of each Resource record
    will be captured into your
    `AppConfig[:as_arclight_test_candidate_directory]` directory.

  * Remove (or comment out) the `AppConfig[:as_arclight_test_mode]`
    line from your configuration and restart ArchivesSpace.

  * Use the `json_diff` tool to compare your pristine mapped files
    against the candidate mapped files (adjusting the paths to match
    your own):

         /path/to/archivesspace/plugins/as_arclight/json_diff/json_diff.sh \
           /tmp/as_arclight_pristine \
           /tmp/as_arclight_candidate \

    If the `json_diff` tool produces no output, your candidate files
    exactly matched your pristine files.  Otherwise, the tool will
    report any differences it finds:

      * Resource records that were not present in both file sets

      * Differences in the records present in each Resource or
        differences in their parent/child relationships

      * Differences in the values of corresponding records
