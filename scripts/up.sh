#!/bin/bash

# This script recursively finds and runs docker-compose.yml files
# within a specified directory using 'docker compose up -d'.

# Function to display usage instructions
usage() {
    echo "Usage: $0 <directory>"
    echo "Recursively finds docker-compose.yml files in the specified directory"
    echo "and runs them using 'docker compose up -d'."
    exit 1
}

# Check if a directory argument is provided
if [ -z "$1" ]; then
    echo "Error: No directory specified."
    usage
fi

# Store the provided directory path
TARGET_DIR="$1"

# Check if the provided path is a valid directory
if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: '$TARGET_DIR' is not a valid directory."
    usage
fi

echo "Searching for docker-compose.yml files in '$TARGET_DIR'..."

# Find all docker-compose.yml files recursively
# -type f: Only consider files
# -name "docker-compose.yml": Match files named "docker-compose.yml"
# -print0: Print results separated by null characters, which is safe for filenames with spaces or special characters
find "$TARGET_DIR" -type f -name "docker-compose.yml" -print0 | while IFS= read -r -d $'\0' compose_file; do
    # Get the directory containing the docker-compose.yml file
    compose_dir=$(dirname "$compose_file")

    echo "----------------------------------------------------"
    echo "Found: $compose_file"
    echo "Changing directory to: $compose_dir"

    # Push the current directory onto the stack and change to the compose file's directory
    # This allows us to easily return to the original directory after running docker compose
    pushd "$compose_dir" > /dev/null

    # Check if docker compose command is available
    if ! command -v docker &> /dev/null || ! docker compose version &> /dev/null; then
        echo "Error: 'docker compose' command not found or not working."
        echo "Please ensure Docker Desktop or Docker Engine with Compose plugin is installed."
        popd > /dev/null # Return to the original directory before exiting
        exit 1
    fi

    echo "Running 'docker compose up -d --remove-orphans --build' in $compose_dir..."
    # Run docker compose up in detached mode (-d)
    # This command will start the services defined in the docker-compose.yml in the background
    if docker compose up -d --remove-orphans --build; then
        echo "Successfully started services for $compose_dir"
    else
        echo "Error: Failed to start services for $compose_dir"
    fi

    # Pop the directory from the stack to return to the previous directory
    popd > /dev/null
    echo "----------------------------------------------------"
done

echo "Script finished."
