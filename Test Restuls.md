Very interesting. When I start the meetingscribe process with teams open but no active call, then manually start recording, then start a call, the mic.wav file starts accumulating bits. 

However, if I start the meetingscribe process with teams open



Test case 1
teams opened
meeting scribe opens
recording starts
Team call starts
OUTCOME: 
-rw-r--r--  1 dan.rohan  staff   9.2M Dec 15 14:26 meeting_2025-12-15_14-25-31_system.wav
-rw-r--r--  1 dan.rohan  staff    44B Dec 15 14:26 meeting_2025-12-15_14-25-31_mic.wav
Only hear the "Call Start" and "Call Stop" tones


Test case 2
Teams opened
Meeting Scribe opened
Team call starts
Recording Starts
Outcome:


