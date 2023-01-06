
About
=====
A project by James Wintermute, jameswinter@protonmail.ch. Started December 2022.

Purpose
=======
The point of this project is the following:

- Create a sha1 hash of all files on a NAS drive, users home dir.
- Store this and use it as a point of reference in disk rotation to spot significant amounts of file change
- Ransomware and Malware are increasingly destructive and how would a user identify if many of their files had been corrupted or destroyed
- Allow the file to be ingested into a SIEM tool such as Splunk

Code
====
- Itention is to keep this as native Bash
- This allows it to be ported to any native linux system with the minimum of compatibility issues
- If it becomes unviable to continue into Python or Perl this can be explored but the preference is Bash

Cleanup artifacts function
==========================
- For spotting duplicate files across a filesystem
- This has been tested and spotted numerous zero data files with the same hash, duplicate files, photos etc.
- Output the duplicate hashes to a file to inform the user
- Also inform the user of files such as .wdmc, thumbs etc which are pointless artifacts on a NAS drive.

# Errors
- Tail is not currently operating in a while loop, unclear how to use find as the input to check. This means it must be cancelled when no input seen via  ctrl-c
- Struggling to get a menu function working


# Improvements

- Currently outputting into a flat file separated by a ','
- Would be useful to improve csv file and output three columns: 'date','hash','path'
- Improve the output to make it easier to see the duplicates and their paths rather than seperate files

## Compare module
- Have a percentage readout of the overall differences. e.g.

50,100 files read
2,100 hashes changed and date difference is x


Future expansion
================
- Awaiting input.

