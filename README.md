# cmdb
给Falcon Plus用的插件
* 每小时采集机器硬件信息并推送到CMDB
* 通过megacli和smartmontools检测机器磁盘故障并推送到falcon报警，通过open IMPI tool检测机器硬件故障并推送到falcon
* 通过检测机器负载，在机器负载高时，对iotop或者top信息进行快照，便于后续追查问题
