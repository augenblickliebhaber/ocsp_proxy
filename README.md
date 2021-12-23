Fork from philfry/ocsp_proxy (https://github.com/philfry/ocsp_proxy)

Changes:
- handle each OCSP request in  an own thread
- add a new thread which does all write/delete operations in the Redis DB. The other threads put their write/delete requests to a thread queue, from which this new thread reads. Because of this you no longer need locks.
