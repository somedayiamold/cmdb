#!/bin/bash
current_dir=$(dirname $0)
cd ${current_dir} || exit 1
sh -x snapshot.sh &> snapshot.log
if [ $? -eq 0 ]; then
   value=0
else
   value=1
fi
echo   '[{"endpoint": "'$(hostname)'", "tags": "project=gaea", "timestamp": '$(date +%s)', "metric": "snapshot", "value": '${value}', "counterType": "GAUGE", "step": 60}]'
