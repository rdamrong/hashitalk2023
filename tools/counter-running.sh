#!/bin/sh

kubectl get pods -n vault --field-selector=status.phase==Running  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | wc -l
