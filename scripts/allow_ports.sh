#!/bin/bash

# Script to allow a list of ports in UFW (Uncomplicated Firewall)

# Function to display usage information
display_usage() {
    echo "Usage: $0 [-f <file_path>] [<port1> [port2] ...]"
    echo ""
    echo "Options:"
    echo "  -f <file_path> : Read ports from the specified file, one port entry per line."
    echo "                   Each line can be: '80', '443/tcp', '6000:6007/udp'."
    echo ""
    echo "Examples:"
    echo "  $0 22 80 443/tcp"
    echo "  $0 3000:3005/tcp 8080/udp"
    echo "  $0 -f /path/to/my_ports.txt"
    echo ""
    echo "Notes:"
    echo "  - For single ports (e.g., '80'), rules for both TCP and UDP will be added."
    echo "  - For port ranges (e.g., '6000:6007'), the protocol (tcp/udp) is REQUIRED."
    echo "  - This script requires 'sudo' privileges."
    exit 1
}

# Check if the script is run with root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with sudo or as root."
   display_usage
fi

# Check if UFW is installed
if ! command -v ufw &> /dev/null; then
    echo "UFW (Uncomplicated Firewall) is not installed."
    echo "Please install it first: sudo apt update && sudo apt install ufw"
    exit 1
fi

declare -a port_entries
file_input=""

# Parse command-line arguments
while (( "$#" )); do
  case "$1" in
    -f|--file)
      if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
        file_input="$2"
        shift 2
      else
        echo "Error: Argument for $1 is missing." >&2
        display_usage
      fi
      ;;
    -*|--*=) # Unsupported flags
      echo "Error: Unsupported flag $1" >&2
      display_usage
      ;;
    *) # Positional arguments (ports)
      port_entries+=("$1")
      shift
      ;;
  esac
done

# If file_input is provided, read from file
if [ -n "$file_input" ]; then
    if [ ! -f "$file_input" ]; then
        echo "Error: File not found: $file_input"
        exit 1
    fi
    if [ ! -r "$file_input" ]; then
        echo "Error: Cannot read file: $file_input (Permission denied?)"
        exit 1
    fi
    echo "Reading ports from file: $file_input"
    # Clear existing port_entries if any were passed as positional args
    port_entries=()
    while IFS= read -r line; do
        # Trim whitespace from the line and skip empty lines or comments
        trimmed_line=$(echo "$line" | xargs)
        if [[ -n "$trimmed_line" && ! "$trimmed_line" =~ ^# ]]; then
            port_entries+=("$trimmed_line")
        fi
    done < "$file_input"
elif [ ${#port_entries[@]} -eq 0 ]; then
    # If no file and no positional arguments, display usage
    display_usage
fi

declare -a commands_to_execute
echo "Preparing UFW rules..."

# Process each port entry (from arguments or file)
for port_entry in "${port_entries[@]}"; do
    if [[ "$port_entry" == *":"* && "$port_entry" == *"/"* ]]; then
        # Format: START:END/PROTOCOL (e.g., 6000:6007/tcp) - Valid
        echo "  - Adding rule for port range: $port_entry"
        commands_to_execute+=("ufw allow $port_entry")
    elif [[ "$port_entry" == *":"* && "$port_entry" != *"/"* ]]; then
        # Format: START:END (e.g., 6000:6007) - Invalid for UFW, requires protocol
        echo "Error: Port range '$port_entry' requires a protocol (e.g., 6000:6007/tcp or 6000:6007/udp)."
        echo "Skipping this entry."
    elif [[ "$port_entry" == *"/"* ]]; then
        # Format: PORT/PROTOCOL (e.g., 443/tcp) - Valid
        echo "  - Adding rule for specific port and protocol: $port_entry"
        commands_to_execute+=("ufw allow $port_entry")
    else
        # Format: PORT (e.g., 80) - Apply both TCP and UDP
        echo "  - Adding rules for port $port_entry (TCP and UDP)"
        commands_to_execute+=("ufw allow $port_entry/tcp")
        commands_to_execute+=("ufw allow $port_entry/udp")
    fi
done

# Check if any commands were generated
if [ ${#commands_to_execute[@]} -eq 0 ]; then
    echo "No valid UFW rules were generated from your input. Exiting."
    exit 0
fi

echo ""
echo "The following UFW commands will be executed:"
for cmd in "${commands_to_execute[@]}"; do
    echo "  - sudo $cmd"
done
echo ""

read -p "Do you want to proceed and apply these UFW rules? (y/N): " confirm
if [[ "$confirm" != [yY] ]]; then
    echo "Operation cancelled."
    exit 0
fi

echo "Applying UFW rules..."
for cmd in "${commands_to_execute[@]}"; do
    echo "Executing: sudo $cmd"
    $cmd
    if [ $? -ne 0 ]; then
        echo "Warning: Command '$cmd' failed. Please check the output above for errors."
    fi
done

echo ""
echo "UFW rules applied. It's recommended to check the status:"
echo "  sudo ufw status verbose"
echo ""
echo "If you are connected via SSH, ensure port 22 (or your custom SSH port) is allowed to avoid lockout."
echo "You can allow SSH with: sudo ufw allow OpenSSH"

