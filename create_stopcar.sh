#!/bin/sh

# Function to create STOPCAR file
create_stop_file() {
    echo "LSTOP = .TRUE." > STOPCAR
}

# Sleep for 30 minutes (1800 seconds)
sleep 60

# Call function to create STOPCAR file after sleep
create_stop_file

echo "STOPCAR file created with 'LSTOP = .TRUE.'"

