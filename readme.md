
## About
- A project by James Wintermute, jameswinter@protonmail.ch. Started December 2022. 
- Overhauled Summer 2025 with assistance from ChatGPT
 
## Purpose
The point of this project is the following:

- Create a hash of all files on a NAS drive, user(s) home paths.
- Store this and use it as a point of reference in disk rotation to spot significant amounts of file change
- Ransomware and Malware are increasingly destructive and how would a user identify if many of their files had been corrupted or destroyed
- Allow the file to be ingested into a SIEM tool such as Splunk
- Recognise and delete duplicate hashes


## Setup
- Download the project from Git
- On your NAS drive create a new folder called 'hasher'
- SCP or copy the hasher project into this space and check the permissions and ownership
- run hasher.sh to begin the main process

### Examples Stage1 - Hashing

<pre>
 ./hasher.sh --pathfile paths.txt --algo sha256 --background
 ./hasher.sh --pathfile paths.txt --algo sha256
 ./find-duplicates.sh hasher/hasher-2025-07-29.txt
</pre>

## Stage 2 - Duplicates
- Run the 'find-duplicates.sh' process
- This will output all the duplicate hashes
- A later stage of the project will assist with the deletion of identified duplicates

## Directory structure

<pre>
├── background.log
└── hashes/
    ├── hasher-2025-07-29.txt
    └── hasher-YYYY-MM-DD.txt (future runs)
</pre>

## See also:
[Facebook Silent Data Corruption](https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/)

