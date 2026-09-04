# heaphjobs

The Heaph Point Board, in game. The website (heaphpoints.com) condensed into one
parchment window for Ashita v4 on HorizonXI:

- **Heaph Jobs**: the active and upcoming banners, every job Heaph has posted,
  and an "I did this, claim it" button on each.
- **Public Jobs**: help wanted and services offered, with Done and Cancel on your own.
- **Post a job**: I need help (bounty in your Heaph Points or gil) or I offer a
  service (gil, points or free).
- **Ask Heaph**: pitch a points event, or request points for something not on the board.
- **Account**: your in-game key and your standing.
- A search box under the title filters every list.

Reading needs nothing. Claiming, posting and asking need your in-game key.

## Install

Unzip so that the files sit exactly here (the folder name must be `heaphjobs`,
not `heaphjobs-main` or `heaphjobs\heaphjobs`):

    Game\addons\heaphjobs\heaphjobs.lua
    Game\addons\heaphjobs\assets\cacert.pem
    Game\addons\heaphjobs\assets\moogle_icon.png
    Game\addons\heaphjobs\assets\paper_tex.jpg

Then in game:

    /addon load heaphjobs

To load it every time, add that line to `Game\scripts\default.txt`.

## Your key

1. On https://heaphpoints.com open the Account tab and sign in (name and password,
   or Discord).
2. Press **Make in-game key** and copy it.
3. In game, either paste it into the addon's Account tab, or type
   `/heaphjobs key <paste>` (with the leading slash, or it goes to chat).

One key per account. Making a new one on the website replaces the old one, so
use the same key on every character and PC. The key is saved per character, in
plain text, at `Game\config\addons\heaphjobs\<Character>\settings.lua`. Anyone
who has it can post and claim as you, so do not share it or that folder. Kill it
from the website (Account tab, Revoke key); "Forget key" in the addon only clears
it on that character.

A key cannot open Heaph's Desk. Admin actions need a browser sign-in.

## Window

- Hold **Shift** and drag to move the board, or lock it in Settings.
- Drag the gold corner grip to resize.
- **Settings** in the title bar: opacity, width, height, the sleeping moogle's
  size and opacity, position lock, reset.
- **X** puts the board to sleep: no fetching, no drawing, just a moogle in the
  corner. Click him to wake it. Shift-drag moves him. He is kept on screen even
  if you change monitors.
- Everything off screen or wrong? `/heaphjobs reset`.
- While a text box has the keyboard, click outside it to give the keys back to
  the game.

## Commands

    /heaphjobs               show or hide the board (/jobs and /pjobs work too)
    /heaphjobs refresh       fetch the board now
    /heaphjobs key <key>     set your in-game key
    /heaphjobs alpha 0.8     board background opacity
    /heaphjobs size 900 700  board size
    /heaphjobs mogsize 72    sleeping moogle size
    /heaphjobs mogalpha 0.8  sleeping moogle opacity
    /heaphjobs reset         defaults, and bring everything back on screen
    /heaphjobs help

To remove the moogle entirely, unload the addon: `/addon unload heaphjobs`.

## How it talks to the site

LuaSocket and LuaSec, both bundled with Ashita, driven from a coroutine that
advances a few small steps per frame, so the game never waits on the network.
The site's certificate is checked against the bundled `assets/cacert.pem` and
must be issued for heaphpoints.com. It reads the public board every two
minutes without the key, and sends the key only with your own account calls
and posts. Nothing else leaves the game.

Creation assisted by ADA. X-32 keeps the ledger.
