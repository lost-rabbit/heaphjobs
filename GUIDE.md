# heaphjobs: the guide

The Heaph Point Board, in game. Everything from heaphpoints.com in one parchment
window inside HorizonXI: Heaph's jobs, the public noticeboard, posting, claiming,
asking Heaph for events, and a search box. This guide gets you from nothing to
claiming a job in about three minutes.

## 1. Install

**Easiest: the one-click installer.**

1. Download `install.bat` from the latest release:
   https://github.com/lost-rabbit/heaphjobs/releases/latest
2. Double-click it. It finds your HorizonXI folder, downloads the latest version,
   puts it in `Game\addons\heaphjobs`, and sets it to load with the game.
3. If the game is already running, type `/addon load heaphjobs` in chat.

Windows may show a "protected your PC" screen the first time because the file is
new and unsigned. Click "More info", then "Run anyway". The script is plain text
in this repo (`install.ps1`) if you want to read what it does first.

Run the same `install.bat` again any time to update.

**By hand.**

1. Download `heaphjobs.zip` from the latest release.
2. Unzip it into `Game\addons`. The folder must be named exactly `heaphjobs`,
   so you end up with `Game\addons\heaphjobs\heaphjobs.lua`. If your unzip tool
   makes `heaphjobs\heaphjobs`, move the inner folder up one level.
3. In game: `/addon load heaphjobs`.
4. To load it every time, add `/addon load heaphjobs` to `Game\scripts\default.txt`.

## 2. First look

The board opens on its own. You can read everything without signing in: the
active and upcoming banners, every job Heaph has posted, help wanted, services
on offer, and the search box under the title.

The window only moves while you hold **Shift** and drag. Drag the gold grip in
the bottom-right corner to resize. **X** puts it to sleep: nothing is fetched or
drawn except a small moogle in the corner. Click him to wake it. Shift-drag moves
him too.

## 3. Your key (to claim, post and ask)

The board needs to know it is you. That is a key, not your password.

1. On https://heaphpoints.com open the **Account** tab and sign in with your name
   and password, or with Discord.
2. Press **Make in-game key** and copy the key.
3. In game, either open the board's **Account** tab and paste it into the box,
   or type in chat:

       /heaphjobs key <paste the key>

   Make sure it starts with the slash, or it goes to whoever you are talking to.

The title bar shows your name and points when the key is accepted. One key per
account: making a new one on the website replaces the old one everywhere, so use
the same key on every character. Revoke it from the website any time.

The key is saved per character, in plain text, at
`Game\config\addons\heaphjobs\<Character>\settings.lua`. Anyone who has it can
post and claim as you. It cannot open Heaph's Desk.

## 4. The tabs

**Heaph Jobs.** Jobs Heaph wants done, with the points he pays. When you have
done one, press "I did this, claim it", say what you did, and send it. Heaph
rules on it from his Desk and the points land on your account.

**Public Jobs.** The shell's noticeboard. Help wanted (someone needs a hand and
has put up a bounty) and Services offered (TH4 help, teleports, crafting). If a
post is yours, you get Done and Cancel buttons on it.

**Post a job.** Two kinds:

- *I need help.* Put up a bounty in your own Heaph Points or in gil. Points come
  off your balance when you post and go to whoever you name when you mark it
  done. Cancel and they come back. Gil stays between you and your helper.
- *I offer a service.* Say what you do and what you ask, in gil, points or free.
  Nothing is held by the site. Take it down whenever you like.

Open-post slots grow with lifetime points earned: one to start, one more for
every 50 earned.

**Ask Heaph.** Pitch an event or job for Heaph to run and pay points for. It goes
to his Desk, he prices it and posts it on Heaph Jobs. The second form requests
points for something you did that is not on the board.

**Account.** Your key, your standing, and the window settings button.

## 5. Settings

The **Settings** button in the title bar opens a small card with:

- Background opacity, width and height sliders.
- The sleeping moogle's size and opacity.
- Lock position (never moves, even with Shift).
- Reset to defaults, which also brings the board and the moogle back on screen.

## 6. Commands

    /heaphjobs               show or hide the board (/jobs and /pjobs work too)
    /heaphjobs refresh       fetch the board now
    /heaphjobs key <key>     set your in-game key
    /heaphjobs alpha 0.8     board background opacity
    /heaphjobs size 900 700  board size
    /heaphjobs mogsize 72    sleeping moogle size
    /heaphjobs mogalpha 0.8  sleeping moogle opacity
    /heaphjobs reset         defaults, and bring everything back on screen
    /heaphjobs help

## 7. When something looks wrong

**"Could not reach the board: ..."** on every tab. The message after the colon
says which step failed. "connect" or "handshake timed out" means the network;
try Refresh. "tls:" anything means the certificate check failed; tell Heaph the
exact words.

**"Your in-game key was refused."** The key was revoked or mistyped. Make a new
one on the website and set it again.

**The board or the moogle vanished.** `/heaphjobs reset` brings both back to
default positions on screen.

**Chat stopped responding to Enter.** A text box on the board has the keyboard.
Click anywhere outside the box to give the keys back to the game.

**Nothing happens when I click the moogle.** You are holding Shift. A plain
click wakes the board; Shift-drag moves him.

**Removing it.** `/addon unload heaphjobs` takes the moogle away for the session.
Delete `Game\addons\heaphjobs` and the line in `scripts\default.txt` to remove
it entirely.

## 8. What it sends

It reads the public board every two minutes without the key, and sends the key
only with your own account calls and posts. The site's certificate is checked
against a bundled CA file and must be issued for heaphpoints.com. Nothing else
leaves the game.

Creation assisted by ADA. X-32 keeps the ledger.
