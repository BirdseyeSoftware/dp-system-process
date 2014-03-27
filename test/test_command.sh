#!/bin/bash

LOOP=continue
while [[ $LOOP == "continue" ]]; do
    echo "out"
    echo "err" >&2
    read LOOP
done
