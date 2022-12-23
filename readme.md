
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

[!errors]
- Tail is not currently operating in a while loop, unclear how to use find as the input to check. This means it must be cancelled when no input seen via  ctrl-c


Improvements
============
- Currently outputting into a flat file separated by a ','
- Would be useful to improve csv file and output three columns: 'date','hash','path'
- Improve the output to make it easy to see the duplicates and their paths

Compare module
==============
- Have a percentage readout of the overall differences. e.g.

50,100 files read
2,100 hashes changed and date difference is x


Secondary purpose
=================
For spotting duplicate files across a filesystem, an additional module may be required for this element


Future expansion
================
