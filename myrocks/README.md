# MyRocks

- Snapshot from `https://github.com/facebook/mysql-5.6.git`

```
$ git log -n 1
commit 7ddbc3c6e127cac00e40b035157b41e19da85638 (HEAD -> fb-mysql-5.6.35, origin/fb-mysql-5.6.35, origin/HEAD)
Author: Luqun Lou <luqun@fb.com>
Date:   Tue Feb 26 11:44:41 2019 -0800

    Remove friend class in Rdb_key_def
    
    Summary:
    The friend class will allow Rdb_tbl_def to access private members in
    Rdb_key_def. since Those provate members had been exposed through public methods.
    It make sense to remove friend class for better code readability and
    maintaince.
    
    Reviewed By: yizhang82
    
    Differential Revision: D14229489
    
    fbshipit-source-id: 0ad08e94374
```
- How to tgz + split

```
# tar, compress + split
tar czpvf - mysql-5.6__2019_02_26 | split -d -b 100M - mysql-5.6__2019_02_26.tgz.part

# untar
cat mysql-5.6__2019_02_26.tgz.part* | tar xzpvf -
```
