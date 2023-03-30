# Introduction

A simple plugin that saves the set of buffers you were editing, and reloads
them when you start kak up the next time.

# Install

Simply copy the save-buffers.kak file into your kak config directory and
source it from your kakrc.

To enable automatic saving and loading, add the following after sourcing the
file:

```
set-option global sb_enable_save_buffers true
set-option global sb_enable_load_buffers true
```

If you make more complex changes to the configuration (see below), you'll
want to add an `sb-initialise` call after setting them, to ensure the changes
are picked up:

```
set-option global sb_enable_save_buffers true
set-option global sb_enable_load_buffers true
... # other changes here
sb-initialise
```

# Usage

There's not much you need to do - it's possible to run the save-buffers and
load-buffers commands manually, but it makes far more sense to enable the
hooks and just let it work . . .

# Behaviour

In order to avoid having kak littering the filesystem with saved buffers
files, the whole thing is gated on the existence of some indication that we're
running in a persistent project of some kind. By default, this means the
existence of a .git or .hg directory, or a number of common project-related
config files - pyproject.toml, cargo.toml, setup.cfg and setup.py. An already
extant saved buffers file also opens the gate, and all the context checks can
be overridden by configuring an environment variable which will be checked.
This doesn't directly override the checks, instead it sets up that variable
as a way to override them - this means you can choose to start any given
session with the override set or not, rather than having it set on a system
wide basis.

Once the gate is opened, the enable load/save buffers options are then used
to enable the automated saving and loading hooks.

When both save and load buffers are enabled the default behaviour is:

* on startup, look for an existing `.kak_save.<session>` file, and if found
  load the contents (after processing)
* whenever a new buffer is created or deleted, either create a new saved
  buffers file, or refresh the existing one (if the file was last modified
  recently enough)

Note that if you're not setting the session name (via `kak -s <name>` most of
the time), the session will default to using the pid of the server - this will
lead to the saved buffers files being named `.kak_save.<pid>`, which will
probably not be very useful. Setting the session name in any context where
you're doing persistent development work is a very good idea, and this is
one of the reasons we check for such a context before allowing our hooks to
run.

The processing that's done shen loading the saved buffer file is fairly
simple:

* make sure the filename is relative to the current directory, and that the
  file exists
* get the mtime of all the files that get through the first filter, and sort
  them in ascending order of age
* run through the list in that order, and open them under the following
  conditions:
  - for files up to a minimum threshold count, open them unconditionally
  - for files above that threshold, open them if they are recent enough
    (relative to the saved buffers file's mtime)
  - once a maximum threshold has been reached, stop opening any more files

This results in the saved buffers list acting like a most recently used cache,
so the files that were most recently modified the last time you were working
in this project will be the ones that are automatically loaded.

As a nice bonus, once we're done loading the files we switch to the buffer
of the most recently modified file, so with luck you'll be able to resume
work right where you left off.

# Configuration

A number of options are available to configure the details of the module's
behaviour.

The minimum and maximum thresholds can be set with the following (these values
are the defaults):

```
set-option global sb_min_load_buffers 20
set-option global sb_max_load_buffers 200
```

The definition of recent used is a time period relative to the mtime of the
saved buffers file - that time period can be set with the following:

```
set-option global sb_age_diff '2 weeks'
```

The value is a string indicating a time period - this is passed to the date(1)
command in order to produce a duration in seconds, using the following
invocation:

```
date -d "1970-01-01T00:00:00+00:00 + <sb_age_diff>" +%s
```

date(1) has some very flexible date parsing code, see the documentation for
details. In general, anything like `1 month` or `1 week` or `3 months` should
work as expected.

The less human-readable option is to set the `sb_age_diff_s` option directly,
which will override the value derived from `sb_age_diff`:

```
set-option global sb_age_diff_s 1209600
```

By default the age check compares the age of the file with the age of the
saved buffers file - this can be changed to compare with the current time by
setting the `sb_use_rel_age` option to `false`. This will prune the list of
files much quicker, and will likely result in hitting the minimum threshold
if you aren't very actively working on a project.
