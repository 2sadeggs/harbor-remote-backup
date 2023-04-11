#!/bin/bash
set -xo pipefail

#备份shell路径和备份日志路径
#备份日志文件太多太大的话可以考虑放到备份目录定时清理
Backup_Shell=/data/backups/shell/harbor-backup.sh
#Backup_Log=/data/backups/shell/harbor-backup.log


#镜像tar包存放路径
Backup_Dir=/data/backups/data
#备份数据存放目录
if [ ! -d "${Backup_Dir}" ]; then
  mkdir -p ${Backup_Dir}
fi

#镜像备份日志文件
Harbor_Backup_Log=${Backup_Dir}/harbor-backup-$(date '+%Y%m%d-%H%M%S-%N').log
#镜像清单文件
Image_List_File=${Backup_Dir}/harbor-images-$(date '+%Y%m%d-%H%M%S-%N').list

#备份文件保留天数
Maintain_Days=3


# save stdout and stderr to file descriptors 3 and 4, then redirect them to"foo"
# exec 3>&1 4>&2 >foo 2>&1
# ...
# restore stdout and stderr
# exec 1>&3 2>&4

#exec 3>&1 4>&2 >>${Backup_Log} 2>&1
exec 3>&1 4>&2 >>${Harbor_Backup_Log} 2>&1

#定义脚本运行的开始时间
Start_Time=`date +%s`

#trap，捕捉到信号，2表示ctrl+c
trap "exec 6>&-;exec 6<&-;exit 0" 2

#创建管道名称
tmp_fifofile="/tmp/$$.fifo"
#新建一个FIFO类型的文件
[ -e ${tmp_fifofile} ] || mkfifo ${tmp_fifofile}

#将FD6指向FIFO类型
exec 6<>${tmp_fifofile}
#将创建的管道文件清除,关联后的文件描述符拥有管道文件的所有特性,所以这时候管道文件可以删除，我们留下文件描述符来用就可以了
rm ${tmp_fifofile}
#指定并发个数
thread_num=24

#根据线程总数量设置令牌个数
#事实上就是在fd6中放置了$thread_num个回车符
for ((i=0;i<${thread_num};i++)); do
    echo
done >&6

#Harbor主机地址
Harbor_Address=harbor.xxxxxx.com
#登录Harbor的用户
Harbor_User=admin
#登录Harbor的用户密码
Harbor_Passwd=pwdxxxxxx
#补充HTTP协议
Scheme=https

echo "$(date '+%Y%m%d-%H%M%S-%N') start>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"

#清理N天前的备份
#find ${Backup_Dir} -name "*.tar" -o -name "*.log" -o -name "*.list" -type f -mtime +${Maintain_Days} | xargs rm -f
find ${Backup_Dir} \( -name "*.tar" -o -name "*.log" -o -name "*.list" \) -type f -mtime +${Maintain_Days} | xargs rm -f
#加不加小括号差别很大 加了小括号括号里边的一起运算 不加的话shell解析任何一个或成功就行
#find -o 选项 也就是逻辑或 或者tar结尾 或者log结尾 或者list结尾

#harbor获取所有镜像列表大概有三个层次
#第一层项目project级别，项目名字如op library 等
#第二层仓库repository级别，仓库名称如 op/uploader op/bakagent op/dpage/pgadmin4 等，注意 仓库名称包含其所属项目名称
#第三层制品artifact级别，制品名称sha256:a02060XXX 等，这个是制品sha256值，且这一层有tag的子结构体，这样就到了第四层，
#我们选用另一个API接口tag
#tag 标签也是第三层 用仓库+标签 再加上仓库地址 基本可以拼出镜像完整URL

#获取所有镜像清单
#项目列表
Project_List=$(curl -u ${Harbor_User}:${Harbor_Passwd} -H "Content-Type: application/json" -X GET ${Scheme}://${Harbor_Address}/api/v2.0/projects -k | jq '.[]' | jq -r '.name')
echo ${Project_List}
for Project in ${Project_List}; do
    echo ${Project}
	#仓库列表，名称包含项目名称
    Repo_List=$(curl -u ${Harbor_User}:${Harbor_Passwd} -H "Content-Type: application/json" -X GET ${Scheme}://${Harbor_Address}/api/v2.0/projects/$Project/repositories -k | jq '.[]' | jq -r '.name')
    for Repo in ${Repo_List}; do
        echo ${Repo}
		#标签列表
        Tag_list=$(curl -u ${Harbor_User}:${Harbor_Passwd} -H "Content-Type: application/json" -X GET ${Scheme}://${Harbor_Address}/v2/$Repo/tags/list -k | jq '.' | jq -r '.tags[]')
        for Tag in ${Tag_list}; do
            echo ${Tag}
			#将所有镜像清单保存到文件
            echo "${Harbor_Address}/${Repo}:${Tag}" >> ${Image_List_File}
        done
    done
done

#下载镜像清单并打包备份
#私有仓库拉取镜像需要登录
docker login -u ${Harbor_User} -p ${Harbor_Passwd} ${Harbor_Address}

Artifact_List=$(cat ${Image_List_File})
for Artifact in ${Artifact_List}; do
    #一个read -u6命令执行一次，就从FD6中减去一个回车符，然后向下执行
    #当FD6中没有回车符时，就停止，从而实现线程数量控制		
    read -u6
    {
	    set -e
        cd ${Backup_Dir} && \
        Image_Name=$(echo ${Artifact} | awk -F/ '{print $3}' |  awk -F: '{print $1}') && \
        Image_Tag=$(echo ${Artifact} | awk -F/ '{print $3}' |  awk -F: '{print $2}') && \
        docker pull ${Artifact} && \
		docker save ${Artifact} -o ${Image_Name}_${Image_Tag}_$(date '+%Y%m%d-%H%M%S-%N').tar
		set +e
        echo >&6
        #当进程结束以后，再向FD6中加上一个回车符，即补上了read -u6减去的那个

		#此方式并发数不可控导致内存溢出，弃用
		#docker pull ${Artifact} && docker save ${Artifact} -o ${Image_Name}-${Image_Tag}-$(date '+%Y%m%d-%H%M%S-%N').tar &
		
		#删除现在镜像，清理磁盘空间。
		#因不是构建而是备份，所以考虑保留下载的镜像，省去下载时间(镜像已有层不再重复下载)，加快备份和导出的时间
        #docker rmi  ${Artifact} 
    }&
done
wait

#定义脚本运行的结束时间
Stop_Time=`date +%s`
#输出脚本运行时间
echo "TIME:`expr ${Stop_Time} - ${Start_Time}`"
#关闭FD6
exec 6<&-
exec 6>&-

echo "$(date '+%Y%m%d-%H%M%S-%N') end<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
exec 1>&3 2>&4
