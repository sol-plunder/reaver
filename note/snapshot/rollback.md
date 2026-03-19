The snapshot file `snap/root.plan` contains all list of all snapshots,
resuming from the most recent one.

If you want to undo to escape some bad change, you can just delete the
newer versions from the file ane resume.

As a consequence, you will always load all data from all snapshots on
every resume.  If this ever gets slow, you can just truncate the file
to only the last snapshot.
