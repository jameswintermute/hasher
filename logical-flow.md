
## Menu
- Welcome Banner, explain function
- Select path(s)
	- Perhaps this should use a list of paths in am input file? A bit clunky this way?
	- Maybe select a path and add that, then add another until done.
	-  e.g. /volume1/Alice, /volume1/Bob
	- List the Disk UID?
		- ls -l /dev/disk/by-uuid/
	
### Choice:
	- Artifacts clean-up check
	- Artifacts clean-up check, then Hasher
	- Just Hasher
	- Quit	

## Start, Cleaning operations
- Find artifacts that are bad e.g.
	- "Thumbs.db", "desktop.ini", "._.DS_Store", ".DS_Store", "._*", ".*"
	- Find bad directories: '.wdmc', '@eaDir'
	- I found lots of these from an old Western Digital NAS drive migration

### Choice
- Review artifacts to Delete
- Delete then Quit
- Skip to Hasher
- Quit

## Hasher main mode
- Start hashing files
- Output them to appropriate file
- Add an appropriate Header Row
- Ideally output format would be comma separated in the form below

<Hash><Filename><Full Path><Date>

Example:
6106f484bd801aaca116139cae9704b7b9,example-file.txt,/volume1/Bob/Files/,2023-10-10-1310 

- Show progress bar, or ongoing Tail-F Or percentage
	- Ensure minimal packages and dependencies required
	
## Hashing Completes
- Write the time taken for the task to the tail of the file OR to an ancilliary file to avoid messing up the csv format

## Cron
- Recommend a CRON tab schedule?
