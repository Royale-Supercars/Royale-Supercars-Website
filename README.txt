ROYALE SUPERCARS - WEBSITE FILES
=================================

HOW TO OPEN THE SITE
--------------------
Double-click "index.html". It opens in your browser.
Keep all files together in this one folder and don't rename them,
or the pages won't be able to find each other.


WHAT EACH FILE IS
-----------------
index.html            The main website (home, fleet, reviews, about, FAQs, social).
loyalty.html          The Royale Rewards page (sign up / log in / member dashboard).
                      You don't open this one directly - the "Loyalty" menu link does.
supabase-schema.sql   The database setup for the rewards + referral system.
                      Only needed when you're ready to make the rewards real (see below).
sample-card-qr.png    An example Royale card QR code, so you can see the scan flow work.
                      Open: index.html works on its own. To test the card scan, open
                      loyalty.html and type ROYALE-8412 in the "Have a card code?" box.


BEFORE THE SITE GOES LIVE - things still to fill in
---------------------------------------------------
Open index.html in any text editor (Notepad / TextEdit) and search for these:

1. WHATSAPP NUMBER - currently a placeholder: 971500000000
   Search for it and replace with the real number (digits only, country code first,
   no + or spaces). It appears in index.html AND loyalty.html.

2. SOCIAL HANDLES - search for "royalesupercars" and replace with the real
   Instagram and TikTok handles.

3. PRICES - search for "3,999" etc. and correct any daily rates.

4. PHOTOS - the two Mercedes V-Class cards still use placeholder artwork.
   Everything else (both Brabus G63s, Huracan, Urus, Escalade) has real photos.

The Instagram feed is already connected and updates itself when you post.


MAKING THE REWARDS SYSTEM REAL (when you're ready)
--------------------------------------------------
Right now the loyalty page works in "demo mode" - accounts are saved only in
the browser you're using, so you can try the whole flow but it isn't a real system.

To go live:
  1. Create a free account at supabase.com and start a new project.
  2. Open the SQL editor there, paste in everything from supabase-schema.sql, run it.
  3. In Supabase, turn on Email authentication.
  4. Copy your project URL and "anon public" key.
  5. Open loyalty.html in a text editor, find SUPABASE_URL and SUPABASE_ANON_KEY
     near the top of the script, and paste them in between the quote marks.

The orange "demo mode" badge disappears once it's connected.


PUTTING THE SITE ON THE INTERNET
--------------------------------
Any host will do. The simplest is netlify.com - make a free account, then drag
this whole folder onto their upload area. It goes live in seconds, and you can
point a real domain (royalesupercars.com) at it afterwards.
