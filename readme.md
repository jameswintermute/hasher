
## About
A project by James Wintermute, jameswinter@protonmail.ch. Started December 2022. 

## Purpose
The point of this project is the following:

- Create a hash of all files on a NAS drive, user(s) home paths.
- Store this and use it as a point of reference in disk rotation to spot significant amounts of file change
- Ransomware and Malware are increasingly destructive and how would a user identify if many of their files had been corrupted or destroyed
- Allow the file to be ingested into a SIEM tool such as Splunk

## Examples

<pre>
 ./hasher.sh --pathfile paths.txt --algo sha256 --background
 ./hasher.sh --pathfile paths.txt --algo sha256
 ./find-duplicates.sh hasher/hasher-2025-07-29.txt
</pre>

## Directory structure

<pre>
hasher/
├── background.log
├── hasher-logs.txt
└── hashes/
    ├── hasher-2025-07-29.txt
    └── hasher-YYYY-MM-DD.txt (future runs)
</pre>

## See also:
[Facebook Data Corruption](https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/)

