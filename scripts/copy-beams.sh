#!/bin/sh

# Copy over parse transforms with dependecies
mkdir -p "$REBAR_BUILD_DIR/lib/merlin/ebin/"
cp _build/default/lib/merlin/ebin/*.beam "$REBAR_BUILD_DIR/lib/merlin/ebin/"

# Rebar is too clever, force it to compile
find "$REBAR_BUILD_DIR/lib" -path "*/.rebar3/*/*.dag" -delete
