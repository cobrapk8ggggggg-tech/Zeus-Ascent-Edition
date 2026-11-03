def group(lines):
    groups=[]
    for line in lines:
        x,y,r,b=line['box'];matches=[]
        for g in groups:
            a,c,d,e=g[-1]['box'];height=max(b-y,e-c)
            if -height*.4<=y-e<height*1.2 and min(r,d)-max(x,a)>min(r-x,d-a)*.25:matches.append(g)
        if matches:min(matches,key=lambda g:abs(g[-1]['box'][3]-y)).append(line)
        else:groups.append([line])
    return groups

