#!/usr/bin/env python

import os

path_common = os.path.abspath(os.path.join(os.getcwd(), '..', '..', '..', 'libs', 'hbb_common', 'protos'))
path_base = os.path.abspath(os.path.join(os.getcwd(), '..', '..', '..', 'libs', 'base', 'protos'))

if os.name == 'nt':
    cmd = r'protoc --ts_proto_opt=esModuleInterop=true --ts_proto_opt=snakeToCamel=false --plugin=protoc-gen-ts_proto=.\node_modules\.bin\protoc-gen-ts_proto.cmd -I "%s" -I "%s" --ts_proto_out=./src/ rendezvous.proto'%(path_common, path_base)
    print(cmd)
    os.system(cmd)
    cmd = r'protoc --ts_proto_opt=esModuleInterop=true --ts_proto_opt=snakeToCamel=false --plugin=protoc-gen-ts_proto=.\node_modules\.bin\protoc-gen-ts_proto.cmd -I "%s" -I "%s" --ts_proto_out=./src/ message.proto'%(path_common, path_base)
    print(cmd)
    os.system(cmd)
else:
    cmd = r'protoc --ts_proto_opt=esModuleInterop=true --ts_proto_opt=snakeToCamel=false --plugin=./node_modules/.bin/protoc-gen-ts_proto -I "%s" -I "%s" --ts_proto_out=./src/ rendezvous.proto'%(path_common, path_base)
    print(cmd)
    os.system(cmd)
    cmd = r'protoc --ts_proto_opt=esModuleInterop=true --ts_proto_opt=snakeToCamel=false --plugin=./node_modules/.bin/protoc-gen-ts_proto -I "%s" -I "%s" --ts_proto_out=./src/ message.proto'%(path_common, path_base)
    print(cmd)
    os.system(cmd)
