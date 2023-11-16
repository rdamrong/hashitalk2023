#!/bin/sh

kubectl get pods -n vault -o go-template='{{ range  $item := .items }}{{ range .status.conditions }}{{ if (or (and (eq .type "PodScheduled") (eq .status "False")) (and (eq .type "Ready") (eq .status "False"))) }}{{ printf "%s\n" $item.metadata.name}} {{ end }}{{ end }}{{ end }}' | wc -l



