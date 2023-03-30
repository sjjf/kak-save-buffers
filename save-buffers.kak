# Automatically save and load buffers for a kak session.
#
# This is just a private thing for my use, unless it grows enough warts to
# want to share with the world . . .
#
# The basic idea is to keep a file containing the list of buffers that are
# open, so that we can load them again when we restart next time - retaining
# some state about the previous work we were doing. In theory we could make
# this into a very sophisticated mechanism of tracking working history, but
# that's totally not worth the trouble - keeping the buffer list is absolutely
# Good Enough(tm) for my use case.
#

# default to off, as this has potential to be intrusive
declare-option -docstring "Whether to automaically save buffer state (default: false)" \
    bool enable_save_buffers false

# default to off, as this has even more potential to be intrusive than saving
# buffers
declare-option -docstring "Whether to automatically load saved buffer state (default: false)" \
    bool enable_load_buffers false

# if there are less than this many entries in the saved buffer list, open
# all of them regardless of their age
declare-option -docstring "Open at least this many buffers, regardless of age (default: 20)" \
    int min_load_buffers 20

# if there are more than this many entries in the saved buffer list, don't
# open any more regardless of how recent they are
#
# This is set to a large default so that it's not going to intrude on things
# very often.
declare-option -docstring "Do not open more than this many buffers (default: 200)" \
    int max_load_buffers 200

# use the age relative to the save file to decide whether to open a file, or
# the absolute age
declare-option -docstring "Use relative age (rather than absolute age) when deciding to load buffers (default: true)" \
    bool rel_age_load_buffers true

# the actual age difference used to decide whether to load a file
#
# Note that this is an absolute age, not a relative one - so '2 weeks', not
# '2 weeks ago'. This value is converted into seconds, and used for all age
# calculations.
#
# Because of how fiddly this kind of processing generally is we
# feed this through date in its date parsing functionality (see the info page
# for details) - the actual invocation is:
# 
# `date -d "1970-01-01T00:00:00+00:00 + ${kak_opt_max_age_load_buffers}" +%s`
#
# which gives us the length in seconds of the specified period.
#
# Yes, there are definitely better ways to deal with this, but none that I
# can think of in a constrained shell environment.
declare-option -docstring "Age at which to stop loading buffers - date(1) string (default '2 weeks')" \
    str max_age_load_buffers '2 weeks'

# if enabled, save the buffer list every time we create a buffer
hook -group 'kak-save-buffers' global BufCreate .* %{
    evaluate-commands %sh{
        if [ "${kak_opt_enable_save_buffers}" = true ]; then
                echo "save-buffers"
        fi
    }
}

# update the saved buffer list when we explicitly close a buffer, too
hook -group 'kak-save-buffers' global BufClose .* %{
    evaluate-commands %sh{
        if [ "${kak_opt_enable_save_buffers}" = true ]; then
                echo "save-buffers"
        fi
    }
}

# if enabled, load buffers on startup
#
# Note that we disable hooks because if we don't the BufCreate hook will fire
# every time we load one of the files. However, we selectively disable just
# the kak-save-buffers hooks because we still want the normal buffer load
# hooks to fire - this includes all the usual things like registering file
# types and so forth.
hook -group 'kak-save-buffers' global KakBegin .* %{
    evaluate-commands %sh{
        if [ "${kak_opt_enable_load_buffers}" = true ]; then
                old_disabled_hooks="${kak_opt_disabled_hooks}"
                echo 'set global disabled_hooks kak-save-buffers'
                echo "load-buffers"
                echo "set global disabled_hooks '$old_disabled_hooks'"
        fi
    }
}

hook -group 'kak-save-buffers' global KakEnd .* %{
    evaluate-commands %sh{
        if [ "${kak_opt_enable_save_buffers}" = true ]; then
            echo 'set global disabled_hooks kak-save-buffers'
        fi
    }
}

# The idea here is to create a command that will save the list of currently
# open files somewhere, so they can be reloaded at the next session.
#
# Only files opened under the current directory will be saved (i.e. the
# buffer name cannot be an absolute path), and only files which exist at
# the time the command is run will be saved.
define-command save-buffers -docstring "Save buffer list to a file in the current directory, for reloading later" %{
    evaluate-commands %sh{
        # save name is ".kak_save.<session>"
        save_file=".kak_save.${kak_session}"
        if [ -f "$save_file" ]; then
                # check to see if we've updated the save file in the last
                # minute, and if so just overwrite it
                now=$(date +%s)
                lmod=$(date -r "$save_file" +%s)
                age=$((now - lmod))
                if [ "$age" -gt 60 ]; then
                        # save file is old, create a new one
                        mv "$save_file" "$save_file.$now"
                        gzip -9 "$save_file.$now"
                        # Note: we're using a conservative find command to
                        # make sure we don't delete things we're not supposed
                        # to
                        find . -maxdepth 1 -mtime +7 -name "$save_file.[12]*.gz" |xargs rm -f
                else
                        # save file is fresh, recreate it
                        rm "$save_file"
                fi
                rm "$ref"
        fi

        set -- ${kak_buflist}
        for buf in "$@"; do
                case $buf in
                        \**)
                                # special buffer, e.g. *debug*
                                ;;
                        \/*)
                                # absolute pathname
                                ;;
                        *)
                                # regular filename, check for existence and age
                                if [ -f "$buf" ]; then
                                        echo "$buf" >> "$save_file"
                                fi
                                ;;
                esac
        done
    }
}

# and the other end, which is intended to be run manually . . .
#
# Note that we only load a file from the list if it's newer than two weeks,
# so that we don't just keep having the list grow and grow indefinitely.
#
# 2023-03-10
# The aging out of files doesn't quite do what I wanted - it means if I
# touched the files in a while they won't be loaded - this probably isn't
# what I want, since it means even though I have some history of what I
# was last doing I'm tossing it for no particular reason.  Instead, I'm
# thinking of sorting by last access date, and then loading /at least/
# some number of files (probably 10, maybe 20), and once I'm past that
# number loading just the ones that are newer than two weeks.
#
# Load files from a saved buffer list.
#
# The gist of this code is pretty simple: read lines from the saved buffer
# file, check to see if the file exists and doesn't break any of the rules,
# and then emit the edit command to load it.
#
# The rules are:
#  * skip any absolute pathnames (so files can only be relative to the
#    current directory)
#  * skip files that are too old (so we don't just keep loading an ever
#    longer list of files)
define-command load-buffers -params 0..1 -docstring "Reload buffer list from a save file" %{
    evaluate-commands %sh{
        # default save name is ".kak_save.<session>", but the user can
        # specify their own filename to load if they want
        save_file=".kak_save.${kak_session}"
        if [ $# -ne 0 ]; then
                save_file="$1"
        fi

        if [ ! -e "$save_file" ]; then
                exit 0
        fi

        # assemble the list of files that exist and aren't absolute
        #
        # The list is new-line separated - it's a bit fiddly to make it \0
        # separated with portable shell code, new line separated at least
        # means the filenames can have spaces and so forth without breaking
        # things. 
        files=""
        while read line ; do
                # clean out comments and trailing white space, continue if
                # line is empty
                line=$(echo "$line" |sed -E -e 's/^([^#]*)#.*$/\1/' -e 's/^(.*)[[:space:]]+$/\1/')
                [ -z "$line" ] && continue
                # canonicalise the path, relative to our PWD
                real_line=$(realpath --relative-base="$PWD" "$line")
                case $real_line in
                        \/*)
                                # absolute pathname - skip
                                ;;
                        *)
                                # regular filename - check for existence, if
                                # it exists add it to the list
                                if [ -f "$real_line" ]; then
                                        if [ -z "$files" ]; then
                                                files="$real_line"
                                        else
                                                files=$(printf "%s\n%s" "$files" "$real_line")
                                        fi
                                fi
                                ;;
                esac
        done < "$save_file"

        # now process the files
        #
        # We want to load the files in ascending order of age - so newest to
        # oldest. We also want to capture their last modified date, and
        # compare that with the age of the save file. And finally, we want to
        # load at least ${kak_opt_min_load_buffers} buffers from the list,
        # regardless of how old they are (but still in age-ascending order).
        #
        # So, we feed the list of files through stat to get the mtime, sort
        # that list and dump to a temp file, which we then process in the next
        # step.
        aged_files=$(mktemp -p /tmp kak_save_buffers.XXXXXX)
        echo "$files" |tr '\n' '\0'|xargs -0 stat -c '%Y %n'|sort -nr > "$aged_files"

        # Processing goes:
        # 
        #   for each line:
        #     have we hit min_load_buffers?
        #       no: emit the edit command and move to next line
        #     have we hit max_load_buffers?
        #       yes: stop processing
        #     is the file mtime newer than the reference time?
        #       no: stop processing
        #     emit the edit command
        #
        # The reference time is max_age_load_buffers before the mtime of the
        # saved buffers file.
        s_ref=$(date -r "$save_file" +%s)
        if [ "${kak_opt_rel_age_load_buffers}" != true ]; then
                s_ref=$(date +%s)
        fi
        max_age=$(date -d "1970-01-01T00:00:00+00:00 + ${kak_opt_max_age_load_buffers}" +%s)
        ref=$((s_ref - max_age))
        loaded=0
        first=""
        while read -r age fname; do
                if [ "$loaded" -le "${kak_opt_min_load_buffers}" ]; then
                        printf "edit %s\n" "$fname"
                        [ -z "$first" ] && first="$fname"
                        continue
                fi
                [ "$loaded" -gt "${kak_opt_max_load_buffers}" ] && break
                [ "$age" -lt "$ref" ] && break
                printf "edit %s\n" "$fname"
                loaded=$((loaded + 1))
        done < "$aged_files"
        rm "$aged_files"

        if [ -n "$first" ]; then
                printf "buffer %s\n" "$first"
        fi

    }
}
