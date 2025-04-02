#!/bin/bash
local_dir="/path/to/local/dir"
remote_dir="user@remotehost:/path/to/remote/dir"
rsync -avz "$local_dir" "$remote_dir"
