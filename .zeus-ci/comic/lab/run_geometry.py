"""Rectangle grouping thresholds from ComicGeometry.group and uniqueLines."""
def group(lines):
    unique=[]
    for line in sorted(lines,key=lambda q:(q['box'][2]-q['box'][0])*(q['box'][3]-q['box'][1]),reverse=True):
        x,y,r,b=line['box'];area=max(1,(r-x)*(b-y))
        if any(max(0,min(r,q['box'][2])-max(x,q['box'][0]))*max(0,min(b,q['box'][3])-max(y,q['box'][1]))/area>.75 for q in unique):continue
        unique.append(line)
    groups=[]
    for line in sorted(unique,key=lambda q:q['box'][1]):
        x,y,r,b=line['box'];matches=[]
        for g in groups:
            a,c,d,e=g[-1]['box'];lh=b-y;previous=e-c
            if lh>(r-x)*1.5 and previous>(d-a)*1.5:
                compatible=any((q['box'][3]-q['box'][1])>(q['box'][2]-q['box'][0])*1.5 and max(x-q['box'][2],q['box'][0]-r)<max(r-x,q['box'][2]-q['box'][0])*1.1 and min(b,q['box'][3])-max(y,q['box'][1])>min(lh,q['box'][3]-q['box'][1])*.6 for q in g)
            else:
                same_row=min(b,e)-max(y,c)>min(lh,previous)*.6 and max(x-d,a-r)<max(lh,previous)*1.2
                next_row=-min(lh,previous)*.5<=y-e<max(lh,previous)*1.2 and min(r,d)-max(x,a)>min(r-x,d-a)*.3
                compatible=same_row or next_row
            if compatible:matches.append(g)
        if matches:min(matches,key=lambda g:abs((g[-1]['box'][1]+g[-1]['box'][3])/2-(y+b)/2)).append(line)
        else:groups.append([line])
    return groups
