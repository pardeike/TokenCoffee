# Token Coffee Sleep Support

This optional component adds independent display-sleep timing, backlight dimming
and enhanced closed-lid operation to Token Coffee. It runs as a native user agent.
It does not use ScriptMonitor.

1. Install Token Coffee 1.2.0 or newer from the Mac App Store.
2. Open Token Coffee once, then choose Quit Token Coffee from its menu.
3. Keep the laptop lid open during installation.
4. Run this command in Terminal:

```sh
/bin/bash "/Volumes/Token Coffee Sleep Support/Scripts/install-sleep-support.sh"
```

The installer prints `ok` after installing and verifying the agent. Open Token
Coffee again afterward. Xcode and Python are not required.

On laptops, enhanced support requires existing permission for exactly these commands:

```text
sudo -n /usr/bin/pmset -a disablesleep 0
sudo -n /usr/bin/pmset -a disablesleep 1
```

The installer does not add administrator permissions. Desktop Macs do not need
these permissions. An administrator can configure the limited laptop permission
by following the setup instructions:

https://github.com/pardeike/TokenCoffee#sleep-support

The agent accepts commands only from the signed Token Coffee app. It restores
owned power and brightness changes when the app exits or disconnects. macOS
restarts the agent after a crash, and startup restores interrupted changes.
It preserves changes it does not own.

Install logs are in `~/Library/Logs/TokenCoffee/`. The agent and its recovery
records are in `~/Library/Application Support/TokenCoffee/Sleep Protection/`.

Source and support: https://github.com/pardeike/TokenCoffee
Mac App Store: https://apps.apple.com/app/id6766599809
