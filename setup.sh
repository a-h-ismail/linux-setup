#!/bin/bash
if [ $EUID -ne 0 ]; then
    echo "You must run this as root, try with sudo."
    exit 1
fi

function get_section {
    # Escaping the backslash twice (once for bash and once for awk)
    # Reason: awk expects this: \[section\] (escape the [] for the regex)
    awk -v "section=\\\\[$1\\\\]" -f extract_data.awk auto-setup.conf
}

system_type=$(get_section System)
add_packages=$(get_section 'Add Packages')
remove_packages=$(get_section 'Remove Packages')
req_flatpacks=$(get_section Flatpak)
system_units=$(get_section 'System Units')
all_users_units=$(get_section 'User Units')
files_mapping=$(get_section Files)
pre_script=$(get_section Pre)
post_script=$(get_section Post)
post_package_install=$(get_section 'Post Packages')

# Execute the pre-install script
if [ -n "$pre_script" ]; then
    $pre_script "$system_type"
fi

# Install/Remove packages depending on your system type
if [ -n "$system_type" ]; then
    # Fedora and derivatives
    if [ "$system_type" == "rpm" ]; then
        dnf install $add_packages -y
        dnf remove $remove_packages -y
        dnf upgrade -y
    fi
    # Debian/Ubuntu derivatives
    if [ "$system_type" == "deb" ]; then
        apt-get update
        apt-get install $add_packages -y
        apt-get remove --purge $remove_packages -y
        apt-get autoremove -y
        apt-get upgrade -y
    fi
fi

# Install Flatpaks
if [ -n "$req_flatpacks" ]; then
    flatpak install $req_flatpacks -y
fi

# Execute post package install script
if [ -n "$post_package_install" ]; then
    $post_package_install "$system_type"
fi

# Copy the files to the given locations
if [ -n "$files_mapping" ]; then
    # Extract the source/destination pairs
    for i in $(seq 1 $(echo "$files_mapping" | wc -l)); do
        # Get source and destination paths by splitting each line at the ':' delimiter
        # May get confused if the filename has : in it, should mitigate that
        source=$(echo "$files_mapping" | awk -F ':' "NR == $i { printf \"%s\", \$1 }")
        destination=$(echo "$files_mapping" | awk -F ':' "NR == $i { printf \"%s\", \$2 }")

        mkdir -p "$destination"
        cp -r "$source" "$destination"
        # If an ACL file exists, restore the ACLs to the destination and delete the file
        if [ -e "$source/acls.txt" ]; then
            tmp=PWD
            cd "$destination"
            setfacl --restore=acls.txt
            rm acls.txt
            cd "$tmp"
        fi
        # Restore SELinux labels
        restorecon -R "$destination" 2> /dev/null
    done
fi

# Enable user units
if [ -n "$all_users_units" ]; then
    # Split username and units using awk
    for i in $(seq $(echo "$all_users_units" | wc -l)); do
        username=$(echo "$all_users_units" | awk -F ':' "NR == $i {print \$1}")
        user_units=$(echo "$all_users_units" | awk -F ':' "NR == $i {print \$2}")
        su - "$username" -c "systemctl --user enable --now $user_units"
    done
fi

# Enable system units as requested
# Reload the service manager since units could be newly installed by the package manager
if [ -n "$system_units" ]; then
    systemctl daemon-reload
    systemctl enable --now $system_units
fi

# Finally the post script
if [ -n "$post_script" ]; then
    $post_script "$system_type"
fi
